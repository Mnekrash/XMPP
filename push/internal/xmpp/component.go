package xmpp

import (
	"context"
	"crypto/sha1" //nolint:gosec // XEP-0114 handshake is defined as SHA-1(stream id + secret)
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"
)

const nsComponent = "jabber:component:accept"

// Handler processes one inbound stanza. It must not block for long.
type Handler func(ctx context.Context, c *Component, stanza *Node)

// Component is a reconnecting XEP-0114 connection to the XMPP server.
type Component struct {
	Addr, Domain, Secret string
	Log                  *slog.Logger

	mu        sync.Mutex
	conn      net.Conn
	connected bool
}

// HandshakeDigest computes the XEP-0114 handshake value.
func HandshakeDigest(streamID, secret string) string {
	sum := sha1.Sum([]byte(streamID + secret)) //nolint:gosec
	return hex.EncodeToString(sum[:])
}

// Connected reports whether the component stream is authenticated.
func (c *Component) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

// Send writes a raw stanza.
func (c *Component) Send(raw string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil || !c.connected {
		return errors.New("component not connected")
	}
	_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := io.WriteString(c.conn, raw)
	return err
}

// Run connects, authenticates and dispatches stanzas until ctx ends, reconnecting with backoff.
func (c *Component) Run(ctx context.Context, h Handler) {
	backoff := time.Second
	for ctx.Err() == nil {
		err := c.session(ctx, h)
		c.mu.Lock()
		c.connected = false
		if c.conn != nil {
			_ = c.conn.Close()
			c.conn = nil
		}
		c.mu.Unlock()
		if ctx.Err() != nil {
			return
		}
		c.Log.Warn("component disconnected", "error", err, "retry_in", backoff.String())
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func (c *Component) session(ctx context.Context, h Handler) error {
	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", c.Addr)
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()
	go func() { <-ctx.Done(); _ = conn.Close() }()

	header := fmt.Sprintf("<?xml version='1.0'?><stream:stream xmlns='%s' xmlns:stream='http://etherx.jabber.org/streams' to='%s'>",
		nsComponent, Escape(c.Domain))
	if _, err := io.WriteString(conn, header); err != nil {
		return err
	}
	dec := xml.NewDecoder(conn)
	streamID := ""
	for streamID == "" {
		tok, err := dec.Token()
		if err != nil {
			return fmt.Errorf("stream header: %w", err)
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "stream" {
			for _, a := range se.Attr {
				if a.Name.Local == "id" {
					streamID = a.Value
				}
			}
			if streamID == "" {
				return errors.New("stream header without id")
			}
		}
	}
	if _, err := io.WriteString(conn, "<handshake>"+HandshakeDigest(streamID, c.Secret)+"</handshake>"); err != nil {
		return err
	}
	first, err := next(dec)
	if err != nil {
		return err
	}
	if first.XMLName.Local != "handshake" {
		return fmt.Errorf("handshake rejected: <%s>", first.XMLName.Local)
	}
	c.mu.Lock()
	c.connected = true
	c.mu.Unlock()
	c.Log.Info("component connected", "domain", c.Domain)

	for {
		stanza, err := next(dec)
		if err != nil {
			return err
		}
		if stanza.XMLName.Local == "error" {
			return errors.New("stream error from server")
		}
		h(ctx, c, stanza)
	}
}

func next(dec *xml.Decoder) (*Node, error) {
	for {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			var n Node
			if err := dec.DecodeElement(&n, &t); err != nil {
				return nil, err
			}
			return &n, nil
		case xml.EndElement:
			return nil, io.EOF // </stream:stream>
		}
	}
}
