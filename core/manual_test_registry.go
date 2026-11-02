package core

import "sync"

type manualTestTarget struct {
	name string
	url  string
}

var manualTests = struct {
	sync.Mutex
	counts map[manualTestTarget]int
}{counts: make(map[manualTestTarget]int)}

func startManualTest(name, url string) func() {
	key := manualTestTarget{name: name, url: url}
	manualTests.Lock()
	manualTests.counts[key]++
	manualTests.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			manualTests.Lock()
			defer manualTests.Unlock()
			if manualTests.counts[key] <= 1 {
				delete(manualTests.counts, key)
			} else {
				manualTests.counts[key]--
			}
		})
	}
}

func isManualTest(name, url string) bool {
	manualTests.Lock()
	defer manualTests.Unlock()
	return manualTests.counts[manualTestTarget{name: name, url: url}] > 0
}
