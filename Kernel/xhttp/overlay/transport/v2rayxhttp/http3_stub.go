//go:build with_xhttp

// kongshan：sing-box-lx 的 HTTP/3 版 XHTTP 依赖它改过的 TLS（STDConfigForQUIC），官方没有，未移植；
// 一律走这个桩，tls.alpn 写 h3 的节点在加载时被拒。h2 / http/1.1 不受影响。

package v2rayxhttp

import (
	"time"

	"github.com/sagernet/sing-box/common/tls"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

// lx: SPEC 104 — without quic-go a config the version rule sends to HTTP/3 is
// refused at load.
func newHTTP3Transport(N.Dialer, M.Socksaddr, tls.Config, time.Duration, func(string)) (func() xmuxConn, error) {
	return nil, E.New(`v2ray-xhttp: HTTP/3 (tls.alpn ["h3"]) is not supported by this build`)
}

func hideQUICError(err error) error {
	return err
}
