package core

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	resetNetworkMu     sync.Mutex
	resetNetworkCancel context.CancelFunc
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

	resetNetworkMu.Lock()
	if resetNetworkCancel != nil {
		resetNetworkCancel() // 立即中止上一轮未完成的等待或 URLTest 请求
	}
	ctx, cancel := context.WithCancel(context.Background())
	resetNetworkCancel = cancel
	resetNetworkMu.Unlock()

	go func(resetCtx context.Context) {
		defer cancel()

		// 1. 使用 select 替代 time.Sleep，支持切网抖动时立即中断退出
		timer := time.NewTimer(1500 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-resetCtx.Done():
			return
		case <-timer.C:
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

		if len(primaryGroups) == 0 && len(secondaryGroups) > 0 {
			primaryGroups = secondaryGroups
			secondaryGroups = nil
		}

		// 3. 次级自动组仅做轻量级 Touch 唤醒懒加载，不抢占切网初期的并发带宽
		for _, sec := range secondaryGroups {
			touchGroup(sec)
		}

		// 4. 主自动组限流并发测速（底层会自动刷新所引用 Provider 节点的延迟，无需重复调用 provider.HealthCheck）
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
				if resetCtx.Err() != nil {
					break
				}
				wg.Add(1)
				sem <- struct{}{}
				go func(g *adapter.Proxy) {
					defer func() {
						<-sem
						wg.Done()
					}()
					if resetCtx.Err() != nil {
						return
					}
					testCtx, testCancel := context.WithTimeout(resetCtx, 3500*time.Millisecond)
					defer testCancel()
					_, _ = g.URLTest(testCtx, url, delayTestExpectedStatus)
				}(group)
			}
			wg.Wait()
		} else {
			// 仅当不存在任何 URLTest/Fallback 策略组时，才触发外部 Provider 健康检查兜底
			for _, pd := range tunnel.ProvidersSnapshot() {
				go func(provider interface{ HealthCheck() }) {
					provider.HealthCheck()
				}(pd)
			}
		}

		if resetCtx.Err() == nil {
			changeRoute(routeMoved)
		}
	}(ctx)
}

func handleCloseConnection(connectionId string) bool {
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}
