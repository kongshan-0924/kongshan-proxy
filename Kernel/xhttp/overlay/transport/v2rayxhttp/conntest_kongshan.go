//go:build with_xhttp

package v2rayxhttp

// kongshan：替换 sing-box-lx 的 conntest_lx.go。原文件把 XHTTP 拨号接进 lx 自己的连接测试追踪
// （common/lxtrace，3000 多行，官方 sing-box 没有）；kongshan 不用它，这里保留同名方法、去掉追踪，
// 行为与 lx 在「没有追踪」时一致：每个方法对 nil 接收者都是空操作，acquire 直接走连接池。

import (
	"context"
	"net/http"
)

type xhttpTrace struct{}

func (c *Client) traceDial(context.Context) *xhttpTrace { return nil }

// resolvedMode is the mode dialMode dials: "auto" resolves as there.
func (c *Client) resolvedMode() string {
	if c.mode != modeAuto {
		return c.mode
	}
	if c.realityEnabled {
		return modeStreamOne
	}
	return modePacketUp
}

func (t *xhttpTrace) end(error) {}

func (t *xhttpTrace) response(*http.Response, error) {}

func (t *xhttpTrace) requestContext(parent context.Context) context.Context { return parent }

func (t *xhttpTrace) acquire(ctx context.Context, c *Client) (*xmuxClient, error) {
	return c.xmux.getContext(ctx)
}
