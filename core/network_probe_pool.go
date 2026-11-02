package core

import (
	"context"
	"sync"
)

// runBoundedProbes owns both the semaphore token and WaitGroup registration.
// A canceled submission never creates a goroutine without a token.
func runBoundedProbes(ctx context.Context, count, limit int, probe func(context.Context, int) bool) bool {
	if count <= 0 || limit <= 0 || ctx.Err() != nil {
		return false
	}
	if limit > count {
		limit = count
	}
	slots := make(chan struct{}, limit)
	var wg sync.WaitGroup
	var mu sync.Mutex
	anySuccess := false
submit:
	for index := 0; index < count; index++ {
		if ctx.Err() != nil {
			break
		}
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			break submit
		}
		// Both select cases may be ready; do not launch after cancellation.
		if ctx.Err() != nil {
			<-slots
			break
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			defer func() { <-slots }()
			if ctx.Err() != nil {
				return
			}
			if probe(ctx, i) {
				mu.Lock()
				anySuccess = true
				mu.Unlock()
			}
		}(index)
	}
	wg.Wait()
	return anySuccess
}
