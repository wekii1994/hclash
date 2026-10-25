package core

import (
	"context"
	"sort"
	"strings"
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

		// 2. 收集自动选路策略组并按优先级排序（主自动组优先）
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

		isPrimary := func(name string) bool {
			lower := strings.ToLower(name)
			return strings.Contains(lower, "自动") ||
				strings.Contains(lower, "auto") ||
				strings.Contains(lower, "url-test") ||
				strings.Contains(lower, "best")
		}
		sort.SliceStable(autoGroups, func(i, j int) bool {
			pi := isPrimary(autoGroups[i].Name())
			pj := isPrimary(autoGroups[j].Name())
			if pi != pj {
				return pi
			}
			return autoGroups[i].Name() < autoGroups[j].Name()
		})

		url := currentTestURL()
		ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		defer cancel()

		for _, group := range autoGroups {
			if resetNetworkSeq.Load() != currentSeq || ctx.Err() != nil {
				break
			}
			_, _ = group.URLTest(ctx, url, delayTestExpectedStatus)
		}
		changeRoute(routeMoved)
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
