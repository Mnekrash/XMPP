// Package xmpp implements the minimal XEP-0114 component side used by the push gateway.
package xmpp

import (
	"bytes"
	"encoding/xml"
	"strings"
)

// Node is a generic XML element tree for stanzas.
type Node struct {
	XMLName  xml.Name
	Attrs    []xml.Attr `xml:",any,attr"`
	Children []Node     `xml:",any"`
	Text     string     `xml:",chardata"`
}

// Attr returns the value of the attribute with the given local name.
func (n *Node) Attr(local string) string {
	for _, a := range n.Attrs {
		if a.Name.Local == local {
			return a.Value
		}
	}
	return ""
}

// Child returns the first child with the given local name and namespace ("" matches any namespace).
func (n *Node) Child(local, ns string) *Node {
	for i := range n.Children {
		c := &n.Children[i]
		if c.XMLName.Local == local && (ns == "" || c.XMLName.Space == ns) {
			return c
		}
	}
	return nil
}

// Path follows a chain of local names (any namespace).
func (n *Node) Path(locals ...string) *Node {
	cur := n
	for _, l := range locals {
		if cur = cur.Child(l, ""); cur == nil {
			return nil
		}
	}
	return cur
}

// FormValues reads a jabber:x:data form into var → first value.
func (n *Node) FormValues() map[string]string {
	out := map[string]string{}
	if n == nil {
		return out
	}
	for i := range n.Children {
		f := &n.Children[i]
		if f.XMLName.Local != "field" {
			continue
		}
		if v := f.Child("value", ""); v != nil {
			out[f.Attr("var")] = strings.TrimSpace(v.Text)
		} else {
			out[f.Attr("var")] = ""
		}
	}
	return out
}

// Escape escapes text and attribute values.
func Escape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return strings.ReplaceAll(b.String(), "'", "&apos;")
}
