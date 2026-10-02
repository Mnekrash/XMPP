package gateway

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/mnekrash/xmpp/push/internal/apns"
	"github.com/mnekrash/xmpp/push/internal/store"
	"github.com/mnekrash/xmpp/push/internal/xmpp"
)

type fakeAPNs struct {
	calls  []string
	result apns.Result
}

func (f *fakeAPNs) Send(_ context.Context, token string, sandbox bool, payload []byte, _ string) (apns.Result, error) {
	f.calls = append(f.calls, string(payload))
	return f.result, nil
}

func parse(t *testing.T, raw string) *xmpp.Node {
	t.Helper()
	var n xmpp.Node
	if err := xml.Unmarshal([]byte(raw), &n); err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	return &n
}

func newGW() (*Gateway, *fakeAPNs) {
	f := &fakeAPNs{result: apns.Result{Status: 200}}
	return &Gateway{XMPPDomain: "chat.test", ComponentJID: "push.chat.test", Store: store.NewMemory(), APNs: f,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil))}, f
}

var deviceKey = make([]byte, 32)

func register(t *testing.T, g *Gateway, from string) (node, secret string) {
	t.Helper()
	req := `<iq type='set' id='r1' from='` + from + `' to='push.chat.test'><command xmlns='http://jabber.org/protocol/commands' node='register-push-apns' action='execute'>` +
		`<x xmlns='jabber:x:data' type='submit'><field var='token'><value>` + strings.Repeat("ab", 32) + `</value></field>` +
		`<field var='environment'><value>sandbox</value></field><field var='device-key'><value>` + base64.StdEncoding.EncodeToString(deviceKey) + `</value></field></x></command></iq>`
	reply := parse(t, g.HandleIQ(context.Background(), parse(t, req)))
	if reply.Attr("type") != "result" {
		t.Fatalf("register failed: %+v", reply)
	}
	v := reply.Path("command", "x").FormValues()
	return v["node"], v["secret"]
}

func publish(node, secret, sender, body string) string {
	return `<iq type='set' id='p1' from='chat.test' to='push.chat.test'><pubsub xmlns='http://jabber.org/protocol/pubsub'>` +
		`<publish node='` + node + `'><item><notification xmlns='urn:xmpp:push:0'><x xmlns='jabber:x:data' type='submit'>` +
		`<field var='FORM_TYPE'><value>urn:xmpp:push:summary</value></field><field var='message-count'><value>1</value></field>` +
		`<field var='last-message-sender'><value>` + sender + `</value></field><field var='last-message-body'><value>` + body + `</value></field>` +
		`</x></notification></item></publish><publish-options><x xmlns='jabber:x:data' type='submit'>` +
		`<field var='FORM_TYPE'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>` +
		`<field var='secret'><value>` + secret + `</value></field></x></publish-options></pubsub></iq>`
}

func TestPublishDeliversContentFreePayloadWithSealedSender(t *testing.T) {
	g, f := newGW()
	node, secret := register(t, g, "bob@chat.test/phone")
	reply := parse(t, g.HandleIQ(context.Background(), parse(t, publish(node, secret, "alice@chat.test/laptop", "TOP SECRET TEXT"))))
	if reply.Attr("type") != "result" || len(f.calls) != 1 {
		t.Fatalf("expected delivery, got %+v / %d calls", reply, len(f.calls))
	}
	payload := f.calls[0]
	for _, leaked := range []string{"TOP SECRET", "alice", "chat.test"} {
		if strings.Contains(payload, leaked) {
			t.Fatalf("payload leaks %q: %s", leaked, payload)
		}
	}
	var p Payload
	_ = json.Unmarshal([]byte(payload), &p)
	if p.APS.Alert.Title != "New message" || p.APS.MutableContent != 1 || p.APS.ThreadID == "" {
		t.Fatalf("unexpected aps: %s", payload)
	}
	env, err := OpenEnvelope(deviceKey, p.E)
	if err != nil || env.Sender != "alice@chat.test/laptop" || env.Conv != "alice@chat.test" || env.Count != 1 {
		t.Fatalf("envelope: %+v %v", env, err)
	}
}

func TestWrongSecretUnknownNodeAndForeignPublisher(t *testing.T) {
	g, f := newGW()
	node, _ := register(t, g, "bob@chat.test/phone")
	cases := map[string]string{
		"not-authorized": publish(node, "wrong", "alice@chat.test", ""),
		"item-not-found": publish("nope", "x", "alice@chat.test", ""),
		"forbidden":      strings.Replace(publish(node, "x", "a@chat.test", ""), "from='chat.test'", "from='evil@chat.test'", 1),
	}
	for want, req := range cases {
		out := g.HandleIQ(context.Background(), parse(t, req))
		if !strings.Contains(out, want) {
			t.Errorf("want %s, got %s", want, out)
		}
	}
	if len(f.calls) != 0 {
		t.Fatalf("no delivery expected, got %d", len(f.calls))
	}
}

func TestPermanentTokenFailureRemovesRegistration(t *testing.T) {
	g, f := newGW()
	node, secret := register(t, g, "bob@chat.test/phone")
	f.result = apns.Result{Status: 410, Reason: "Unregistered", Permanent: true}
	out := g.HandleIQ(context.Background(), parse(t, publish(node, secret, "alice@chat.test", "")))
	if !strings.Contains(out, "item-not-found") {
		t.Fatalf("expected item-not-found for ejabberd to disable the node, got %s", out)
	}
	if _, err := g.Store.Get(context.Background(), node); err != store.ErrNotFound {
		t.Fatalf("registration should be deleted, err=%v", err)
	}
}

func TestMuteSuppressesDeliveryAndForeignDomainCannotRegister(t *testing.T) {
	g, f := newGW()
	node, secret := register(t, g, "bob@chat.test/phone")
	conv := OpaqueID(deviceKey, "alice@chat.test")
	until := time.Now().Add(time.Hour).Unix()
	mute := `<iq type='set' id='m' from='bob@chat.test/phone' to='push.chat.test'><command xmlns='http://jabber.org/protocol/commands' node='mute-conversation'>` +
		`<x xmlns='jabber:x:data' type='submit'><field var='node'><value>` + node + `</value></field><field var='conversation'><value>` + conv +
		`</value></field><field var='until'><value>` + strconv.FormatInt(until, 10) + `</value></field></x></command></iq>`
	if out := g.HandleIQ(context.Background(), parse(t, mute)); !strings.Contains(out, "type='result'") {
		t.Fatalf("mute failed: %s", out)
	}
	g.HandleIQ(context.Background(), parse(t, publish(node, secret, "alice@chat.test/x", "")))
	if len(f.calls) != 0 {
		t.Fatal("muted conversation was delivered")
	}
	req := `<iq type='set' id='r2' from='mallory@other.test/x' to='push.chat.test'><command xmlns='http://jabber.org/protocol/commands' node='register-push-apns'/></iq>`
	if out := g.HandleIQ(context.Background(), parse(t, req)); !strings.Contains(out, "forbidden") {
		t.Fatalf("foreign domain registered: %s", out)
	}
}
