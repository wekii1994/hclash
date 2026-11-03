package core

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleCloseGroupStaleConnections(groupName, oldProxyName string, switchTime time.Time) {
	if groupName == "" || oldProxyName == "" {
		return
	}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		info := c.Info()
		if info == nil {
			return true
		}
		if !switchTime.IsZero() && info.Start.After(switchTime) {
			return true
		}
		hasGroup := false
		hasOldProxy := false
		for _, node := range info.Chain {
			if node == groupName {
				hasGroup = true
			}
			if node == oldProxyName {
				hasOldProxy = true
			}
		}
		if hasGroup && hasOldProxy {
			_ = c.Close()
		}
		return true
	})
}

func init() {
	outboundgroup.OnGroupNowChanged = func(group C.ProxyAdapter, groupName, before, after string) {
		configMu.Lock()
		defer configMu.Unlock()
		selectMu.Lock()
		defer selectMu.Unlock()

		activeProxy := tunnel.AllProxies()[groupName]
		if activeProxy == nil {
			return
		}
		if group != nil {
			if p, ok := activeProxy.(*adapter.Proxy); ok {
				if p.ProxyAdapter != group {
					log.Debugln("[Failover] Suppressed stale failover from unloaded group instance %s", groupName)
					return
				}
			} else if activeProxy != group {
				log.Debugln("[Failover] Suppressed stale failover from unloaded group instance %s", groupName)
				return
			}
		}

		log.Infoln("[Failover] Proxy group %s auto switched from [%s] to [%s] via passive failure detection", groupName, before, after)
		handleCloseGroupStaleConnections(groupName, before, time.Now())
		refreshRouteLocked(routeMoved)
	}
}

const (
	networkSettleDelay      = 300 * time.Millisecond
	networkRetryBackoff     = 1200 * time.Millisecond
	groupProbeTimeout       = 2800 * time.Millisecond
	primaryProbeConcurrency = 3
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

func isAutoGroup(p *adapter.Proxy) bool {
	if p == nil {
		return false
	}
	switch p.Type() {
	case C.URLTest, C.Fallback:
		return true
	default:
		return false
	}
}

func hasPrimaryAutoKeyword(name string) bool {
	lower := strings.ToLower(name)
	for _, kw := range []string{"自动", "auto", "url-test", "best", "优选", "极速", "主力"} {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

// classifyAutoGroups 结合当前活跃路由拓扑（Selector -> Now 引用链）与名称特征，划分主次自动策略组。
func classifyAutoGroups() (primary []*adapter.Proxy, secondary []*adapter.Proxy) {
	allProxies := tunnel.Proxies()
	activeNames := make(map[string]struct{})

	// 沿着所有 Selector 的当前选中项向下展开，标记正在承载流量的策略组
	for _, raw := range allProxies {
		p, ok := raw.(*adapter.Proxy)
		if !ok || p.Type() != C.Selector {
			continue
		}
		curr := p
		for depth := 0; depth < 6 && curr != nil; depth++ {
			pg, ok := curr.ProxyAdapter.(outboundgroup.ProxyGroup)
			if !ok {
				break
			}
			nowName := pg.Now()
			if nowName == "" {
				break
			}
			if _, visited := activeNames[nowName]; visited {
				break
			}
			activeNames[nowName] = struct{}{}
			nextRaw, exists := allProxies[nowName]
			if !exists {
				break
			}
			nextProxy, ok := nextRaw.(*adapter.Proxy)
			if !ok {
				break
			}
			curr = nextProxy
		}
	}

	for _, raw := range allProxies {
		p, ok := raw.(*adapter.Proxy)
		if !ok || !isAutoGroup(p) {
			continue
		}
		_, isActive := activeNames[p.Name()]
		if isActive || hasPrimaryAutoKeyword(p.Name()) {
			primary = append(primary, p)
		} else {
			secondary = append(secondary, p)
		}
	}

	if len(primary) == 0 && len(secondary) > 0 {
		primary = secondary
		secondary = nil
	}

	sort.SliceStable(primary, func(i, j int) bool {
		_, aActive := activeNames[primary[i].Name()]
		_, bActive := activeNames[primary[j].Name()]
		if aActive != bActive {
			return aActive
		}
		return primary[i].Name() < primary[j].Name()
	})
	return primary, secondary
}

func snapshotGroupSelections(groups []*adapter.Proxy) map[string]string {
	res := make(map[string]string, len(groups))
	for _, g := range groups {
		if pg, ok := g.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
			res[g.Name()] = pg.Now()
		}
	}
	return res
}

func hasSelectionChanged(before map[string]string, groups []*adapter.Proxy) bool {
	for _, g := range groups {
		if pg, ok := g.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
			if before[g.Name()] != pg.Now() {
				return true
			}
		}
	}
	return false
}

type contextHealthCheckedGroup interface {
	HealthCheckContext(context.Context) (map[string]uint16, error)
}

// Require the companion Mihomo patch at compile time, not only at runtime.
var _ contextHealthCheckedGroup = (*outboundgroup.URLTest)(nil)
var _ contextHealthCheckedGroup = (*outboundgroup.Fallback)(nil)

func probeGroupsConcurrently(ctx context.Context, groups []*adapter.Proxy) bool {
	return runBoundedProbes(ctx, len(groups), primaryProbeConcurrency,
		func(probeCtx context.Context, index int) bool {
			checker, ok := groups[index].ProxyAdapter.(contextHealthCheckedGroup)
			if !ok {
				return false
			}
			testCtx, cancel := context.WithTimeout(probeCtx, groupProbeTimeout)
			defer cancel()
			results, err := checker.HealthCheckContext(testCtx)
			return err == nil && len(results) > 0
		})
}

func waitOrCancel(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func cancelResetNetwork() {
	resetNetworkMu.Lock()
	if resetNetworkCancel != nil {
		resetNetworkCancel()
		resetNetworkCancel = nil
	}
	resetNetworkMu.Unlock()
}

func handleResetNetwork() {
	handleCloseConnections()
	handleClearDnsCache()

	resetNetworkMu.Lock()
	if resetNetworkCancel != nil {
		resetNetworkCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	resetNetworkCancel = cancel
	resetNetworkMu.Unlock()

	startEpoch, _ := routeStamp()

	go func(resetCtx context.Context) {
		defer cancel()

		if !waitOrCancel(resetCtx, networkSettleDelay) {
			return
		}
		if endEpoch, _ := routeStamp(); endEpoch != startEpoch {
			return
		}

		primaryGroups, secondaryGroups := classifyAutoGroups()
		beforeSelections := snapshotGroupSelections(primaryGroups)

		for _, sec := range secondaryGroups {
			touchGroup(sec)
		}

		if len(primaryGroups) > 0 {
			ok := probeGroupsConcurrently(resetCtx, primaryGroups)
			if !ok && waitOrCancel(resetCtx, networkRetryBackoff) {
				handleClearDnsCache()
				if endEpoch, _ := routeStamp(); endEpoch == startEpoch {
					_ = probeGroupsConcurrently(resetCtx, primaryGroups)
				}
			}
		} else {
			for _, pd := range tunnel.ProvidersSnapshot() {
				if resetCtx.Err() != nil {
					break
				}
				if endEpoch, _ := routeStamp(); endEpoch != startEpoch {
					break
				}
				go func(provider interface{ HealthCheck() }) {
					provider.HealthCheck()
				}(pd)
			}
		}

		if resetCtx.Err() != nil {
			return
		}
		if endEpoch, _ := routeStamp(); endEpoch != startEpoch {
			return
		}

		if hasSelectionChanged(beforeSelections, primaryGroups) {
			handleCloseConnections()
		}
		changeRoute(routeMoved)
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
