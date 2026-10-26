package core

import (
	"context"
	"sort"
	"strings"
	"sync"
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

type touchable interface {
	Touch()
}

func touchGroup(group *adapter.Proxy) {
	if group == nil {
		return
	}
	if t, ok := group.ProxyAdapter.(touchable); ok {
		t.Touch()
		return
	}
	_ = group.Unwrap(nil, true)
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

		// 1. 异步触发外部 Provider 健康检查，避免阻塞主自动组的切网测速
		for _, pd := range tunnel.ProvidersSnapshot() {
			go func(provider interface{ HealthCheck() }) {
				provider.HealthCheck()
			}(pd)
		}

		// 2. 收集自动选路策略组并区分主自动组与次级自动组
		var primaryGroups []*adapter.Proxy
		var secondaryGroups []*adapter.Proxy

		isPrimary := func(name string) bool {
			lower := strings.ToLower(name)
			return strings.Contains(lower, "自动") ||
				strings.Contains(lower, "auto") ||
				strings.Contains(lower, "url-test") ||
				strings.Contains(lower, "best")
		}

		for _, proxy := range tunnel.Proxies() {
			p, ok := proxy.(*adapter.Proxy)
			if !ok {
				continue
			}
			switch p.Type() {
			case C.URLTest, C.Fallback:
				if isPrimary(p.Name()) {
					primaryGroups = append(primaryGroups, p)
				} else {
					secondaryGroups = append(secondaryGroups, p)
				}
			}
		}

		// 兜底保护：若未命中任何关键字，所有自动策略组均作为主自动组享受立即测速
		if len(primaryGroups) == 0 && len(secondaryGroups) > 0 {
			primaryGroups = secondaryGroups
			secondaryGroups = nil
		}

		if len(primaryGroups) == 0 {
			return
		}
		if resetNetworkSeq.Load() != currentSeq {
			return
		}

		// 3. 对次级自动组：执行轻量级 Touch() 唤醒懒加载健康检查，不耗费大量网络并发
		for _, sec := range secondaryGroups {
			touchGroup(sec)
		}

		// 4. 对主自动组：使用带限流（最大并发 3）的协程池并发测速，每个组享受独立的 3500ms 超时
		if len(primaryGroups) > 0 {
			sort.SliceStable(primaryGroups, func(i, j int) bool {
				return primaryGroups[i].Name() < primaryGroups[j].Name()
			})

			url := currentTestURL()
			maxConcurrent := 3
			if len(primaryGroups) < maxConcurrent {
				maxConcurrent = len(primaryGroups)
			}
			sem := make(chan struct{}, maxConcurrent)
			var wg sync.WaitGroup

			for _, group := range primaryGroups {
				if resetNetworkSeq.Load() != currentSeq {
					break
				}
				wg.Add(1)
				sem <- struct{}{}
				go func(g *adapter.Proxy) {
					defer func() {
						<-sem
						wg.Done()
					}()
					if resetNetworkSeq.Load() != currentSeq {
						return
					}
					ctx, cancel := context.WithTimeout(context.Background(), 3500*time.Millisecond)
					defer cancel()
					_, _ = g.URLTest(ctx, url, delayTestExpectedStatus)
				}(group)
			}
			wg.Wait()
		}

		if resetNetworkSeq.Load() == currentSeq {
			changeRoute(routeMoved)
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
