package gateway

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/mnekrash/xmpp/push/internal/apns"
	"github.com/mnekrash/xmpp/push/internal/store"
	"github.com/mnekrash/xmpp/push/internal/xmpp"
)

const (
	nsCommands    = "http://jabber.org/protocol/commands"
	nsPubSub      = "http://jabber.org/protocol/pubsub"
	nsPush        = "urn:xmpp:push:0"
	nsDiscoInfo   = "http://jabber.org/protocol/disco#info"
	nsData        = "jabber:x:data"
	CmdRegister   = "register-push-apns"
	CmdUnregister = "unregister-push"
	CmdMute       = "mute-conversation"
	AlertTitle    = "New message"
)

// Sender delivers to APNs (apns.Client in production, a fake in tests).
type Sender interface {
	Send(ctx context.Context, token string, sandbox bool, payload []byte, collapseID string) (apns.Result, error)
}

// Gateway handles component stanzas.
type Gateway struct {
	XMPPDomain   string // our users' domain; registrations must come from it, publishes from it exactly
	ComponentJID string
	Store        store.Store
	APNs         Sender // nil: deliveries fail with an internal error (APNs not configured)
	Log          *slog.Logger
	Now          func() time.Time
}

// LogID is a non-reversible short id for logs (no JIDs or tokens in info logs).
func LogID(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:4])
}

func bare(jid string) string {
	if i := strings.IndexByte(jid, '/'); i >= 0 {
		return jid[:i]
	}
	return jid
}

func domainOf(jid string) string {
	b := bare(jid)
	if i := strings.IndexByte(b, '@'); i >= 0 {
		return b[i+1:]
	}
	return b
}

// Handle is the xmpp.Handler.
func (g *Gateway) Handle(ctx context.Context, c *xmpp.Component, st *xmpp.Node) {
	if st.XMLName.Local != "iq" {
		return
	}
	reply := g.HandleIQ(ctx, st)
	if reply != "" {
		if err := c.Send(reply); err != nil {
			g.Log.Warn("send reply failed", "error", err)
		}
	}
}

// HandleIQ returns the raw reply stanza for an inbound IQ (exported for tests).
func (g *Gateway) HandleIQ(ctx context.Context, iq *xmpp.Node) string {
	typ, from, id := iq.Attr("type"), iq.Attr("from"), iq.Attr("id")
	if typ == "result" || typ == "error" {
		return ""
	}
	switch {
	case typ == "get" && iq.Child("query", nsDiscoInfo) != nil:
		return g.result(iq, fmt.Sprintf(`<query xmlns='%s'><identity category='pubsub' type='push' name='Push gateway'/>`+
			`<feature var='%s'/><feature var='%s'/><feature var='%s'/></query>`, nsDiscoInfo, nsPush, nsCommands, nsDiscoInfo))
	case typ == "set" && iq.Child("command", nsCommands) != nil:
		return g.command(ctx, iq, iq.Child("command", nsCommands))
	case typ == "set" && iq.Child("pubsub", nsPubSub) != nil:
		return g.publish(ctx, iq, iq.Child("pubsub", nsPubSub))
	default:
		_ = from
		_ = id
		return g.errorReply(iq, "cancel", "feature-not-implemented")
	}
}

// ------------------------------------------------------------------ commands (from users)

func (g *Gateway) command(ctx context.Context, iq, cmd *xmpp.Node) string {
	from := iq.Attr("from")
	if domainOf(from) != g.XMPPDomain || !strings.Contains(bare(from), "@") {
		return g.errorReply(iq, "auth", "forbidden")
	}
	account := bare(from)
	form := cmd.Child("x", nsData).FormValues()
	node := cmd.Attr("node")
	switch node {
	case CmdRegister:
		token := strings.ToLower(strings.TrimSpace(form["token"]))
		key, err := base64.StdEncoding.DecodeString(form["device-key"])
		env := form["environment"]
		if !validToken(token) || err != nil || len(key) != 32 || (env != "sandbox" && env != "production") {
			return g.errorReply(iq, "modify", "bad-request")
		}
		pushNode, secret := randomHex(16), randomB64(32)
		reg := store.Registration{Node: pushNode, SecretHash: store.HashSecret(secret), AccountJID: account,
			APNsToken: token, Sandbox: env == "sandbox", DeviceKey: key}
		if err := g.Store.Put(ctx, reg); err != nil {
			g.Log.Error("store registration", "error", err)
			return g.errorReply(iq, "wait", "internal-server-error")
		}
		g.Log.Info("registered", "node", LogID(pushNode), "account", LogID(account), "env", env)
		return g.result(iq, completed(node, map[string]string{"node": pushNode, "secret": secret}))
	case CmdUnregister:
		reg, err := g.Store.Get(ctx, form["node"])
		if err == nil && reg.AccountJID == account {
			_ = g.Store.Delete(ctx, reg.Node)
			g.Log.Info("unregistered", "node", LogID(reg.Node))
		}
		return g.result(iq, completed(node, nil)) // idempotent
	case CmdMute:
		reg, err := g.Store.Get(ctx, form["node"])
		if err != nil || reg.AccountJID != account {
			return g.errorReply(iq, "cancel", "item-not-found")
		}
		var until time.Time
		if s := form["until"]; s != "" && s != "0" {
			sec, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				return g.errorReply(iq, "modify", "bad-request")
			}
			until = time.Unix(sec, 0)
		}
		if err := g.Store.SetMute(ctx, reg.Node, form["conversation"], until); err != nil {
			return g.errorReply(iq, "wait", "internal-server-error")
		}
		return g.result(iq, completed(node, nil))
	default:
		return g.errorReply(iq, "cancel", "item-not-found")
	}
}

func validToken(t string) bool {
	if len(t) < 32 || len(t) > 200 {
		return false
	}
	_, err := hex.DecodeString(t)
	return err == nil
}

// ------------------------------------------------------------------ publish (from the XMPP server)

// Payload is the APNs JSON (exported for tests).
type Payload struct {
	APS struct {
		Alert struct {
			Title string `json:"title"`
		} `json:"alert"`
		MutableContent int    `json:"mutable-content"`
		Sound          string `json:"sound,omitempty"`
		ThreadID       string `json:"thread-id,omitempty"`
	} `json:"aps"`
	E string `json:"e,omitempty"`
}

func (g *Gateway) publish(ctx context.Context, iq, ps *xmpp.Node) string {
	if bare(iq.Attr("from")) != g.XMPPDomain { // only our own server may publish
		return g.errorReply(iq, "auth", "forbidden")
	}
	pub := ps.Child("publish", nsPubSub)
	if pub == nil {
		return g.errorReply(iq, "modify", "bad-request")
	}
	node := pub.Attr("node")
	reg, err := g.Store.Get(ctx, node)
	if errors.Is(err, store.ErrNotFound) {
		g.Log.Info("publish for unknown node", "node", LogID(node))
		return g.errorReply(iq, "cancel", "item-not-found") // mod_push disables the node
	} else if err != nil {
		return g.errorReply(iq, "wait", "internal-server-error")
	}
	opts := ps.Path("publish-options", "x").FormValues()
	if !reg.SecretMatches(opts["secret"]) {
		g.Log.Warn("publish with wrong secret", "node", LogID(node))
		return g.errorReply(iq, "auth", "not-authorized")
	}
	summary := pub.Path("item", "notification", "x").FormValues()
	sender := summary["last-message-sender"]
	count, _ := strconv.Atoi(summary["message-count"])
	conv := bare(sender)

	var p Payload
	p.APS.Alert.Title = AlertTitle
	p.APS.MutableContent = 1
	p.APS.Sound = "default"
	if conv != "" {
		thread := OpaqueID(reg.DeviceKey, conv)
		p.APS.ThreadID = thread
		if until, err := g.Store.MutedUntil(ctx, reg.Node, thread); err == nil && until.After(g.now()) {
			g.Log.Info("muted, not delivered", "node", LogID(node))
			return g.result(iq, "")
		}
		if p.E, err = SealEnvelope(reg.DeviceKey, Envelope{V: EnvelopeVersion, Sender: sender, Conv: conv, Count: count}); err != nil {
			return g.errorReply(iq, "wait", "internal-server-error")
		}
	}
	// Defence in depth: the server is configured with include_body=false; never forward a body even if present.
	body, _ := json.Marshal(p)

	if g.APNs == nil {
		g.Log.Error("APNs not configured; notification dropped", "node", LogID(node))
		return g.errorReply(iq, "wait", "internal-server-error")
	}
	res, err := g.APNs.Send(ctx, reg.APNsToken, reg.Sandbox, body, p.APS.ThreadID)
	if err != nil {
		g.Log.Warn("apns transport error", "node", LogID(node), "error", err)
		return g.errorReply(iq, "wait", "remote-server-timeout")
	}
	switch {
	case res.Status == 200:
		_ = g.Store.MarkSuccess(ctx, reg.Node)
		g.Log.Info("delivered", "node", LogID(node), "apns_id", res.APNsID)
		return g.result(iq, "")
	case res.Permanent:
		_ = g.Store.Delete(ctx, reg.Node)
		g.Log.Info("token invalid, registration removed", "node", LogID(node), "status", res.Status, "reason", res.Reason)
		return g.errorReply(iq, "cancel", "item-not-found")
	default:
		g.Log.Warn("apns rejected", "node", LogID(node), "status", res.Status, "reason", res.Reason)
		return g.errorReply(iq, "wait", "resource-constraint")
	}
}

func (g *Gateway) now() time.Time {
	if g.Now != nil {
		return g.Now()
	}
	return time.Now()
}

// ------------------------------------------------------------------ stanza helpers

func (g *Gateway) result(iq *xmpp.Node, payload string) string {
	return fmt.Sprintf("<iq type='result' id='%s' from='%s' to='%s'>%s</iq>",
		xmpp.Escape(iq.Attr("id")), xmpp.Escape(g.ComponentJID), xmpp.Escape(iq.Attr("from")), payload)
}

func (g *Gateway) errorReply(iq *xmpp.Node, typ, condition string) string {
	return fmt.Sprintf("<iq type='error' id='%s' from='%s' to='%s'><error type='%s'><%s xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>",
		xmpp.Escape(iq.Attr("id")), xmpp.Escape(g.ComponentJID), xmpp.Escape(iq.Attr("from")), typ, condition)
}

func completed(node string, fields map[string]string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "<command xmlns='%s' node='%s' status='completed' sessionid='%s'>", nsCommands, xmpp.Escape(node), randomHex(8))
	if len(fields) > 0 {
		fmt.Fprintf(&b, "<x xmlns='%s' type='result'>", nsData)
		for _, k := range []string{"node", "secret"} {
			if v, ok := fields[k]; ok {
				fmt.Fprintf(&b, "<field var='%s'><value>%s</value></field>", k, xmpp.Escape(v))
			}
		}
		b.WriteString("</x>")
	}
	b.WriteString("</command>")
	return b.String()
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func randomB64(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}
