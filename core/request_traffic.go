package core

import (
	"sync"
	"time"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

// mihomo announces a connection only as it opens, and has no hook for its
// close; the request list learns the traffic that follows from these reports.
const requestTrafficInterval = time.Second

type RequestTraffic struct {
	Id       string `json:"id"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Closed   bool   `json:"closed,omitempty"`
	Host     string `json:"host,omitempty"`
	Process  string `json:"process,omitempty"`
}

type watchedRequest struct {
	tracker  statistic.Tracker
	upload   int64
	download int64
	// The tracker is announced before the manager stores it, so a request
	// missing from the manager on its first report may still be opening.
	fresh bool
	// A closed tracker is released immediately; only final scalar totals are retried.
	terminal *RequestTraffic
	host     string
	process  string
}

type requestTrafficWatch struct {
	mu       sync.Mutex
	requests map[string]*watchedRequest
	running  bool
}

var currentRequestTraffic = requestTrafficWatch{
	requests: map[string]*watchedRequest{},
}

func (w *requestTrafficWatch) add(tracker statistic.Tracker) (start bool) {
	info := tracker.Info()
	w.mu.Lock()
	defer w.mu.Unlock()
	host := ""
	process := ""
	if info != nil && info.Metadata != nil {
		host = info.Metadata.Host
		if host == "" && info.Metadata.DstIP.IsValid() {
			host = info.Metadata.DstIP.String()
		}
		process = info.Metadata.Process
	}
	w.requests[tracker.ID()] = &watchedRequest{
		tracker:  tracker,
		upload:   info.UploadTotal.Load(),
		download: info.DownloadTotal.Load(),
		fresh:    true,
		host:     host,
		process:  process,
	}
	start = !w.running
	w.running = true
	return start
}

func (w *requestTrafficWatch) collect(
	isOpen func(id string) bool,
	queue func([]RequestTraffic) (queued bool),
) (watching bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	var changed []RequestTraffic
	for id, request := range w.requests {
		if request.terminal != nil {
			changed = append(changed, *request.terminal)
			continue
		}
		closed := !request.fresh && !isOpen(id)
		request.fresh = false
		info := request.tracker.Info()
		upload, download := info.UploadTotal.Load(), info.DownloadTotal.Load()
		sample := RequestTraffic{
			Id:       id,
			Upload:   upload,
			Download: download,
			Closed:   closed,
			Host:     request.host,
			Process:  request.process,
		}
		if closed {
			request.terminal = &sample
			request.tracker = nil
			changed = append(changed, sample)
		} else if upload != request.upload || download != request.download {
			changed = append(changed, sample)
		}
	}
	queued := len(changed) == 0 || queue(changed)
	if queued {
		for _, traffic := range changed {
			if traffic.Closed {
				delete(w.requests, traffic.Id)
			} else {
				request := w.requests[traffic.Id]
				request.upload, request.download = traffic.Upload, traffic.Download
			}
		}
	}
	w.running = len(w.requests) > 0
	return w.running
}

func (w *requestTrafficWatch) clear() {
	w.mu.Lock()
	defer w.mu.Unlock()
	clear(w.requests)
	w.running = false
}

func watchRequestTraffic(tracker statistic.Tracker) {
	if currentRequestTraffic.add(tracker) {
		go runRequestTrafficWatch()
	}
}

func runRequestTrafficWatch() {
	ticker := time.NewTicker(requestTrafficInterval)
	defer ticker.Stop()
	for range ticker.C {
		if !hasEventListener() {
			currentRequestTraffic.clear()
			return
		}
		watching := currentRequestTraffic.collect(
			func(id string) bool {
				return statistic.DefaultManager.Get(id) != nil
			},
			func(changed []RequestTraffic) bool {
				return sendMessage(RequestTrafficMessage, changed)
			},
		)
		if !watching {
			return
		}
	}
}
