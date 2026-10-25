package core

import (
	"context"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() bool {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
	return true
}

func handleResetConnections() bool {
	resolver.ResetConnection()
	return true
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections.
func handleResetNetwork() {
	handleCloseConnections()
	handleClearDnsCache()

	// 异步触发所有 Provider 与自动选路策略组重测，避免阻塞主控协程
	go func() {
		for _, pd := range tunnel.ProvidersSnapshot() {
			go pd.HealthCheck()
		}

		url := currentTestURL()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		for _, proxy := range tunnel.Proxies() {
			p, ok := proxy.(*adapter.Proxy)
			if !ok {
				continue
			}
			switch p.Type() {
			case C.URLTest, C.Fallback, C.LoadBalance:
				go func(pr *adapter.Proxy) {
					_, _ = pr.URLTest(ctx, url, delayTestExpectedStatus)
				}(p)
			}
		}
	}()
}

func handleCloseConnection(connectionId string) bool {
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}
