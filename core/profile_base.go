package core

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// What makes a profile large stays in the Core; the overlay the host sends
// back replaces every other section.
var profileBaseSections = []string{"proxies", "proxy-groups", "sub-rules"}

func handleGetProfileBase(path string) (*ProfileBase, error) {
	defer scheduleLoadMemoryRelease()
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(buf)
	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	base := &ProfileBase{
		Digest:      hex.EncodeToString(digest[:]),
		MatchRules:  []string{},
		Proxies:     len(raw.Proxy),
		ProxyGroups: len(raw.ProxyGroup),
		Rules:       len(raw.Rule),
	}
	for _, rule := range raw.Rule {
		if isMatchRule(rule) {
			base.MatchRules = append(base.MatchRules, rule)
		}
	}
	raw.Proxy, raw.ProxyGroup, raw.Rule, raw.SubRules = nil, nil, nil, nil
	base.Config = raw
	return base, nil
}

func handleGetProfileOutbounds(path string) (*ProfileOutbounds, error) {
	defer scheduleLoadMemoryRelease()
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	return &ProfileOutbounds{Proxies: outboundsOf(raw.Proxy), ProxyGroups: outboundsOf(raw.ProxyGroup)}, nil
}

func outboundsOf(mappings []map[string]any) []ProfileOutbound {
	outbounds := make([]ProfileOutbound, 0, len(mappings))
	for _, mapping := range mappings {
		name, _ := mapping["name"].(string)
		kind, _ := mapping["type"].(string)
		outbounds = append(outbounds, ProfileOutbound{Name: name, Type: kind})
	}
	return outbounds
}

// The merged config goes to the spill directory, so the host reads it as text
// and never decodes it.
func handleBuildProfile(base *SetupBase) (string, error) {
	defer scheduleLoadMemoryRelease()
	document, err := mergeProfileBase(base)
	if err != nil {
		return "", err
	}
	dir, err := makeSpilledResponseDir()
	if err != nil {
		return "", err
	}
	path, err := writeDocumentFile(dir, "*.yaml", document)
	if err != nil {
		return "", err
	}
	scheduleReclaimOwnership()
	return path, nil
}

// Mirrors Rule.parse in Dart, which reads the type from the first field.
func isMatchRule(rule string) bool {
	kind, _, _ := strings.Cut(rule, ",")
	return strings.EqualFold(strings.TrimSpace(kind), "MATCH")
}

const (
	defaultExpectedStatus = "200-204"
	defaultTolerance      = 50
	defaultExcludeFilter  = "(?i)(剩余|到期|官网|提示|群|traffic|expire|website|notice|订阅)"
)

var dummyNodeRegex = regexp.MustCompile(defaultExcludeFilter)

func isProtectedProxyName(name string) bool {
	switch strings.ToUpper(name) {
	case "DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "GLOBAL":
		return true
	default:
		return false
	}
}

func loadConfigWithBase(base *SetupBase, configPath string) (*config.Config, error) {
	return loadConfigWithBaseAndTimeout(base, configPath, 0)
}

func loadConfigWithBaseAndTimeout(base *SetupBase, configPath string, healthCheckTimeout int) (*config.Config, error) {
	document, err := mergeProfileBase(base)
	if err != nil {
		return nil, err
	}
	if root, err := documentMapping(document); err == nil {
		patchHealthCheckTimeoutNode(root, healthCheckTimeout)
	}
	raw := config.DefaultRawConfig()
	if err := document.Decode(raw); err != nil {
		return nil, err
	}
	patchHealthCheckTimeoutRaw(raw, healthCheckTimeout)
	if err := writeConfigDocument(configPath, document); err != nil {
		return nil, err
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return nil, err
	}
	return withPlatformLimits(cfg), nil
}

func patchHealthCheckTimeoutNode(root *yaml.Node, timeout int) {
	if root == nil {
		return
	}
	timeoutStr := ""
	if timeout > 0 {
		timeoutStr = strconv.Itoa(timeout)
	}
	groups := mappingValue(root, "proxy-groups")
	if groups != nil && groups.Kind == yaml.SequenceNode {
		for _, group := range groups.Content {
			if group.Kind != yaml.MappingNode {
				continue
			}
			typeNode := mappingValue(group, "type")
			if typeNode != nil && (typeNode.Value == "url-test" || typeNode.Value == "fallback" || typeNode.Value == "load-balance") {
				if timeoutStr != "" {
					setMappingValue(group, "timeout", &yaml.Node{
						Kind:  yaml.ScalarNode,
						Tag:   "!!int",
						Value: timeoutStr,
					})
				}
				if mappingValue(group, "expected-status") == nil {
					setMappingValue(group, "expected-status", &yaml.Node{
						Kind:  yaml.ScalarNode,
						Tag:   "!!str",
						Value: defaultExpectedStatus,
					})
				}
				if typeNode.Value == "url-test" || typeNode.Value == "load-balance" {
					tolNode := mappingValue(group, "tolerance")
					needTol := false
					if tolNode == nil {
						needTol = true
					} else if val, err := strconv.Atoi(strings.TrimSpace(tolNode.Value)); err == nil && val < defaultTolerance {
						needTol = true
					}
					if needTol {
						setMappingValue(group, "tolerance", &yaml.Node{
							Kind:  yaml.ScalarNode,
							Tag:   "!!int",
							Value: strconv.Itoa(defaultTolerance),
						})
					}
				}
				useNode := mappingValue(group, "use")
				if useNode != nil && useNode.Kind == yaml.SequenceNode && len(useNode.Content) > 0 {
					filterNode := mappingValue(group, "exclude-filter")
					if filterNode == nil {
						setMappingValue(group, "exclude-filter", &yaml.Node{
							Kind:  yaml.ScalarNode,
							Tag:   "!!str",
							Value: defaultExcludeFilter,
						})
					} else if !strings.Contains(filterNode.Value, "剩余") {
						filterNode.Value = filterNode.Value + "|" + defaultExcludeFilter
					}
				}
				proxiesNode := mappingValue(group, "proxies")
				if proxiesNode != nil && proxiesNode.Kind == yaml.SequenceNode && len(proxiesNode.Content) > 0 {
					var kept []*yaml.Node
					for _, pNode := range proxiesNode.Content {
						if pNode.Kind == yaml.ScalarNode {
							if isProtectedProxyName(pNode.Value) || !dummyNodeRegex.MatchString(pNode.Value) {
								kept = append(kept, pNode)
							}
						} else {
							kept = append(kept, pNode)
						}
					}
					if len(kept) > 0 {
						proxiesNode.Content = kept
					}
				}
			}
		}
	}
	providers := mappingValue(root, "proxy-providers")
	if providers != nil && providers.Kind == yaml.MappingNode {
		for i := 1; i < len(providers.Content); i += 2 {
			provider := providers.Content[i]
			if provider.Kind != yaml.MappingNode {
				continue
			}
			hc := mappingValue(provider, "health-check")
			if hc != nil && hc.Kind == yaml.MappingNode {
				if timeoutStr != "" {
					setMappingValue(hc, "timeout", &yaml.Node{
						Kind:  yaml.ScalarNode,
						Tag:   "!!int",
						Value: timeoutStr,
					})
				}
				if mappingValue(hc, "expected-status") == nil {
					setMappingValue(hc, "expected-status", &yaml.Node{
						Kind:  yaml.ScalarNode,
						Tag:   "!!str",
						Value: defaultExpectedStatus,
					})
				}
			}
			filterNode := mappingValue(provider, "exclude-filter")
			if filterNode == nil {
				setMappingValue(provider, "exclude-filter", &yaml.Node{
					Kind:  yaml.ScalarNode,
					Tag:   "!!str",
					Value: defaultExcludeFilter,
				})
			} else if !strings.Contains(filterNode.Value, "剩余") {
				filterNode.Value = filterNode.Value + "|" + defaultExcludeFilter
			}
		}
	}
}

func patchHealthCheckTimeoutRaw(raw *config.RawConfig, timeout int) {
	if raw == nil {
		return
	}
	for _, group := range raw.ProxyGroup {
		if group == nil {
			continue
		}
		groupType, _ := group["type"].(string)
		if groupType == "url-test" || groupType == "fallback" || groupType == "load-balance" {
			if timeout > 0 {
				group["timeout"] = timeout
			}
			if expected, ok := group["expected-status"].(string); !ok || expected == "" {
				group["expected-status"] = defaultExpectedStatus
			}
			if groupType == "url-test" || groupType == "load-balance" {
				tol := 0
				switch t := group["tolerance"].(type) {
				case int:
					tol = t
				case float64:
					tol = int(t)
				case string:
					tol, _ = strconv.Atoi(t)
				}
				if tol < defaultTolerance {
					group["tolerance"] = defaultTolerance
				}
			}
			if use, ok := group["use"].([]any); ok && len(use) > 0 {
				combineExcludeFilterRaw(group, defaultExcludeFilter)
			}
			if proxies, ok := group["proxies"].([]any); ok && len(proxies) > 0 {
				var filtered []any
				for _, p := range proxies {
					if name, ok := p.(string); ok {
						if isProtectedProxyName(name) || !dummyNodeRegex.MatchString(name) {
							filtered = append(filtered, p)
						}
					} else {
						filtered = append(filtered, p)
					}
				}
				if len(filtered) > 0 {
					group["proxies"] = filtered
				}
			}
		}
	}
	for _, provider := range raw.ProxyProvider {
		if provider == nil {
			continue
		}
		if hc, ok := provider["health-check"].(map[string]any); ok {
			if timeout > 0 {
				hc["timeout"] = timeout
			}
			if expected, ok := hc["expected-status"].(string); !ok || expected == "" {
				hc["expected-status"] = defaultExpectedStatus
			}
		}
		combineExcludeFilterRaw(provider, defaultExcludeFilter)
	}
}

func combineExcludeFilterRaw(target map[string]any, filter string) {
	if existing, ok := target["exclude-filter"].(string); ok && existing != "" {
		if !strings.Contains(existing, "剩余") {
			target["exclude-filter"] = existing + "|" + filter
		}
		return
	}
	target["exclude-filter"] = filter
}

func mergeProfileBase(base *SetupBase) (*yaml.Node, error) {
	buf, err := os.ReadFile(base.Path)
	if err != nil {
		return nil, err
	}
	if buf, err = age.DecryptBytes(buf); err != nil {
		return nil, fmt.Errorf("decrypt config error: %w", err)
	}
	retag := bytes.Contains(buf, []byte("short-id"))
	var profileDocument, overlayDocument yaml.Node
	if err := yaml.Unmarshal(buf, &profileDocument); err != nil {
		return nil, err
	}
	if err := yaml.Unmarshal([]byte(base.Overlay), &overlayDocument); err != nil {
		return nil, err
	}
	profile, err := documentMapping(&profileDocument)
	if err != nil {
		return nil, err
	}
	root, err := documentMapping(&overlayDocument)
	if err != nil {
		return nil, err
	}
	for _, key := range profileBaseSections {
		if value := mappingValue(profile, key); value != nil {
			setMappingValue(root, key, value)
		}
	}
	rules, err := appendRules(mappingValue(root, "rules"), mappingValue(profile, "rules"))
	if err != nil {
		return nil, err
	}
	if rules != nil {
		setMappingValue(root, "rules", rules)
	}
	if retag {
		retagShortIDs(root)
	}
	return &yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{root}}, nil
}

func documentMapping(document *yaml.Node) (*yaml.Node, error) {
	node := document
	if node.Kind == yaml.DocumentNode && len(node.Content) > 0 {
		node = resolveAlias(node.Content[0])
	}
	switch {
	case node.Kind == yaml.MappingNode:
		return node, nil
	case node.Kind == 0, node.Kind == yaml.DocumentNode, isNull(node):
		return &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}, nil
	}
	return nil, fmt.Errorf("line %d: a config must be a mapping", node.Line)
}

// A key the mapping lacks is looked up in its merge keys, as the decoder does.
func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	var sources []*yaml.Node
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		name, value := mapping.Content[i], mapping.Content[i+1]
		if name.Kind != yaml.ScalarNode {
			continue
		}
		if name.ShortTag() == "!!merge" {
			sources = append(sources, value)
		} else if name.Value == key {
			return value
		}
	}
	for _, source := range sources {
		source = resolveAlias(source)
		candidates := []*yaml.Node{source}
		if source.Kind == yaml.SequenceNode {
			candidates = source.Content
		}
		for _, candidate := range candidates {
			if candidate = resolveAlias(candidate); candidate.Kind == yaml.MappingNode {
				if value := mappingValue(candidate, key); value != nil {
					return value
				}
			}
		}
	}
	return nil
}

func setMappingValue(mapping *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if name := mapping.Content[i]; name.Kind == yaml.ScalarNode && name.Value == key {
			mapping.Content[i+1] = value
			return
		}
	}
	mapping.Content = append(
		mapping.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		value,
	)
}

// The overlay's rules are the ones the host adds in front of the profile's.
func appendRules(added, profile *yaml.Node) (*yaml.Node, error) {
	if profile == nil {
		return nil, nil
	}
	added, profile = resolveAlias(added), resolveAlias(profile)
	if added == nil || isNull(added) || (added.Kind == yaml.SequenceNode && len(added.Content) == 0) {
		return profile, nil
	}
	if isNull(profile) {
		return added, nil
	}
	if added.Kind != yaml.SequenceNode || profile.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("line %d: rules must be a list", profile.Line)
	}
	content := make([]*yaml.Node, 0, len(added.Content)+len(profile.Content))
	content = append(append(content, added.Content...), profile.Content...)
	return &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: content}, nil
}

func resolveAlias(node *yaml.Node) *yaml.Node {
	for node != nil && node.Kind == yaml.AliasNode && node.Alias != nil {
		node = node.Alias
	}
	return node
}

func isNull(node *yaml.Node) bool {
	return node.Kind == yaml.ScalarNode && node.ShortTag() == "!!null"
}

// config.yaml is read again without this process: by the Android service
// starting on its own and by mihomo's own reload through the controller.
func writeConfigDocument(path string, document *yaml.Node) error {
	temporary, err := writeDocumentFile(filepath.Dir(path), ".config-*.yaml", document)
	if err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	scheduleReclaimOwnership()
	return nil
}

func writeDocumentFile(dir, pattern string, document *yaml.Node) (string, error) {
	inlineAliases(document)
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	writer := bufio.NewWriterSize(file, 1<<20)
	err = errors.Join(
		encodeConfigMapping(writer, document.Content[0]),
		writer.Flush(),
		file.Close(),
		os.Chmod(file.Name(), 0o644),
	)
	if err != nil {
		_ = os.Remove(file.Name())
		return "", err
	}
	return file.Name(), nil
}

// One Encode call keeps every event it emitted until it returns, several times
// the size of a large profile, so a long top-level list goes out in slices.
const encodeSliceLength = 4096

// The mapping is drained as it is written, so the parse that follows does not
// share the heap with the whole tree.
func encodeConfigMapping(w io.Writer, mapping *yaml.Node) error {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		key, value := mapping.Content[i], mapping.Content[i+1]
		mapping.Content[i+1] = nil
		if value.Kind != yaml.SequenceNode || len(value.Content) <= encodeSliceLength {
			pair := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: []*yaml.Node{key, value}}
			if err := encodeYamlPiece(w, pair, nil); err != nil {
				return err
			}
			continue
		}
		if err := encodeYamlPiece(w, key, []byte(":\n")); err != nil {
			return err
		}
		for start := 0; start < len(value.Content); start += encodeSliceLength {
			items := value.Content[start:min(start+encodeSliceLength, len(value.Content))]
			slice := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: items}
			if err := encodeYamlPiece(w, slice, nil); err != nil {
				return err
			}
			clear(items)
		}
	}
	return nil
}

// Each piece is a document of its own; an end marker left between two of them
// would end config.yaml there.
func encodeYamlPiece(w io.Writer, node *yaml.Node, suffix []byte) error {
	var buffer bytes.Buffer
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(2)
	if err := errors.Join(encoder.Encode(node), encoder.Close()); err != nil {
		return err
	}
	piece := bytes.TrimSuffix(buffer.Bytes(), []byte("...\n"))
	if suffix != nil {
		piece = append(bytes.TrimSuffix(piece, []byte("\n")), suffix...)
	}
	_, err := w.Write(piece)
	return err
}

// An anchor may sit in a section the overlay replaced, so every alias is
// written out in full, as the host's own encoder always did.
func inlineAliases(root *yaml.Node) {
	visited := map[*yaml.Node]struct{}{}
	var walk func(node *yaml.Node)
	walk = func(node *yaml.Node) {
		if _, seen := visited[node]; seen {
			return
		}
		if node.Anchor != "" {
			visited[node] = struct{}{}
			node.Anchor = ""
		}
		for i, child := range node.Content {
			child = resolveAlias(child)
			node.Content[i] = child
			walk(child)
		}
	}
	walk(root)
}
