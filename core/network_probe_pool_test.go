package core

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestBoundedProbesCanceledBeforeStart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	success := runBoundedProbes(ctx, 5, 3, func(context.Context, int) bool {
		called = true
		return true
	})
	if success || called {
		t.Fatal("canceled work was executed")
	}
}

func TestBoundedProbesCancellationWhileWaitingForSlot(t *testing.T) {
	for iteration := 0; iteration < 100; iteration++ {
		ctx, cancel := context.WithCancel(context.Background())
		entered := make(chan struct{})
		done := make(chan struct{})
		var exited atomic.Int32
		go func() {
			defer close(done)
			runBoundedProbes(ctx, 100, 1, func(ctx context.Context, index int) bool {
				if index == 0 {
					close(entered)
				}
				<-ctx.Done()
				exited.Add(1)
				return false
			})
		}()
		select {
		case <-entered:
		case <-time.After(time.Second):
			cancel()
			t.Fatal("first probe never started")
		}
		cancel()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("canceled pool failed to join its workers")
		}
		if exited.Load() != 1 {
			t.Fatalf("completed workers = %d, want 1", exited.Load())
		}
	}
}

func TestBoundedProbesLimitAndJoin(t *testing.T) {
	var active atomic.Int32
	var maximum atomic.Int32
	var completed atomic.Int32
	success := runBoundedProbes(context.Background(), 30, 3,
		func(_ context.Context, index int) bool {
			current := active.Add(1)
			for previous := maximum.Load(); current > previous; previous = maximum.Load() {
				if maximum.CompareAndSwap(previous, current) {
					break
				}
			}
			time.Sleep(time.Millisecond)
			active.Add(-1)
			completed.Add(1)
			return index == 7
		})
	if !success || maximum.Load() > 3 || active.Load() != 0 || completed.Load() != 30 {
		t.Fatalf("success=%v max=%d active=%d complete=%d", success,
			maximum.Load(), active.Load(), completed.Load())
	}
}
