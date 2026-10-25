package core

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var resetNetworkSeq atomic.Uint64

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

	seq := resetNetworkSeq.Add(1)
	go func(currentSeq uint64) {
		// 等待 1.5 秒让系统完成 Wi-Fi / 蜂窝网络路由切换，防止 0ms 抢跑导致全部报 network unreachable
		time.Sleep(1500 * time.Millisecond)
		if resetNetworkSeq.Load() != currentSeq {
			return
		}

		// 1. 顺序触发外部 Provider 健康检查（内部自带并发限制）
		for _, pd := range tunnel.ProvidersSnapshot() {
			if resetNetworkSeq.Load() != currentSeq {
				return
			}
			pd.HealthCheck()
		}

		// 2. 收集自动选路策略组，仅对第 1 个自动组执行一次 URLTest，其余组调用 Touch()，避免多组同时并发轰炸同一批节点
		var autoGroups []*adapter.Proxy
		for _, proxy := range tunnel.Proxies() {
			p, ok := proxy.(*adapter.Proxy)
			if !ok {
				continue
			}
			switch p.Type() {
			case C.URLTest, C.Fallback:
				autoGroups = append(autoGroups, p)
			}
		}

		if len(autoGroups) == 0 || resetNetworkSeq.Load() != currentSeq {
			return
		}

		url := currentTestURL()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		_, _ = autoGroups[0].URLTest(ctx, url, delayTestExpectedStatus)
		for i := 1; i < len(autoGroups); i++ {
			if t, ok := autoGroups[i].ProxyAdapter.(interface{ Touch() }); ok {
				t.Touch()
			}
		}
	}(seq)
}

func handleCloseConnection(connectionId string) bool {
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}
