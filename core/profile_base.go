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
	defaultHealthCheckTimeout  = 3000
	defaultExpectedStatus      = "200-204"
	optimalTolerance           = 50  // 容差控制在 50ms，避免基站延迟波动时频繁横跳
	maxAllowedTolerance        = 80  // 超过 80ms 的容差一律压低到 50ms
	optimalHealthCheckInterval = 120 // 健康检查周期最高不超过 120 秒
)

func normalizeHealthCheckTimeout(timeout int) int {
	if timeout <= 0 {
		return defaultHealthCheckTimeout
	}
	return timeout
}

func loadConfigWithBase(base *SetupBase, configPath string) (*config.Config, error) {
	return loadConfigWithBaseAndTimeout(base, configPath, defaultHealthCheckTimeout)
}

func loadConfigWithBaseAndTimeout(base *SetupBase, configPath string, healthCheckTimeout int) (*config.Config, error) {
	document, err := mergeProfileBase(base)
	if err != nil {
		return nil, err
	}
	return decodeAndBuildConfig(document, configPath, healthCheckTimeout)
}

func decodeAndBuildConfig(document *yaml.Node, writePath string, healthCheckTimeout int) (*config.Config, error) {
	healthCheckTimeout = normalizeHealthCheckTimeout(healthCheckTimeout)
	if root, err := documentMapping(document); err == nil {
		patchHealthCheckTimeoutNode(root, healthCheckTimeout)
	}
	raw := config.DefaultRawConfig()
	if err := document.Decode(raw); err != nil {
		return nil, err
	}
	if writePath != "" {
		if err := writeConfigDocument(writePath, document); err != nil {
			return nil, err
		}
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return nil, err
	}
	return withPlatformLimits(cfg), nil
}

// clampYAMLInt 确保整型字段在 (0, maxVal] 范围内；若缺失、格式非法或超限则设为 defaultVal。
func clampYAMLInt(mapping *yaml.Node, key string, defaultVal, maxVal int) {
	if node := mappingValue(mapping, key); node != nil {
		node = resolveAlias(node)
		if val, err := strconv.Atoi(strings.TrimSpace(node.Value)); err == nil && val > 0 && val <= maxVal {
			return
		}
	}
	setMappingValue(mapping, key, &yaml.Node{
		Kind:  yaml.ScalarNode,
		Tag:   "!!int",
		Value: strconv.Itoa(defaultVal),
	})
}

// ensureYAMLString 确保字符串字段非空；若缺失或为空白则设为 defaultVal。
func ensureYAMLString(mapping *yaml.Node, key, defaultVal string) {
	if node := mappingValue(mapping, key); node != nil {
		node = resolveAlias(node)
		if strings.TrimSpace(node.Value) != "" {
			return
		}
	}
	setMappingValue(mapping, key, &yaml.Node{
		Kind:  yaml.ScalarNode,
		Tag:   "!!str",
		Value: defaultVal,
	})
}

func cloneYAMLNode(node *yaml.Node, depth ...int) *yaml.Node {
	if node == nil {
		return nil
	}
	d := 0
	if len(depth) > 0 {
		d = depth[0]
	}
	if d > 64 {
		return nil
	}
	node = resolveAlias(node)
	clone := *node
	if len(node.Content) > 0 {
		clone.Content = make([]*yaml.Node, len(node.Content))
		for i, child := range node.Content {
			clone.Content[i] = cloneYAMLNode(child, d+1)
		}
	}
	return &clone
}

func forEachMappingEntry(mapping *yaml.Node, fn func(key string, value *yaml.Node)) {
	mapping = resolveAlias(mapping)
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return
	}
	seenKeys := make(map[string]bool)
	var visit func(m *yaml.Node, depth int)
	visit = func(m *yaml.Node, depth int) {
		if depth > 64 {
			return
		}
		m = resolveAlias(m)
		if m == nil || m.Kind != yaml.MappingNode {
			return
		}
		// First pass: direct non-<< keys
		for i := 0; i+1 < len(m.Content); i += 2 {
			k := m.Content[i]
			if k.Kind == yaml.ScalarNode && k.Value != "<<" {
				if !seenKeys[k.Value] {
					seenKeys[k.Value] = true
					fn(k.Value, m.Content[i+1])
				}
			}
		}
		// Second pass: merge keys (<<)
		for i := 0; i+1 < len(m.Content); i += 2 {
			k := m.Content[i]
			if k.Kind == yaml.ScalarNode && k.Value == "<<" {
				source := resolveAlias(m.Content[i+1])
				if source == nil {
					continue
				}
				if source.Kind == yaml.SequenceNode {
					for _, item := range source.Content {
						visit(item, depth+1)
					}
				} else if source.Kind == yaml.MappingNode {
					visit(source, depth+1)
				}
			}
		}
	}
	visit(mapping, 0)
}

func patchHealthCheckTimeoutNode(root *yaml.Node, timeout int) {
	if root == nil {
		return
	}
	root = resolveAlias(root)
	timeout = normalizeHealthCheckTimeout(timeout)

	if groups := mappingValue(root, "proxy-groups"); groups != nil {
		groups = resolveAlias(groups)
		if groups.Kind == yaml.SequenceNode {
			for _, group := range groups.Content {
				group = resolveAlias(group)
				if group.Kind != yaml.MappingNode {
					continue
				}
				typeNode := resolveAlias(mappingValue(group, "type"))
				if typeNode == nil {
					continue
				}
				switch strings.ToLower(strings.TrimSpace(typeNode.Value)) {
				case "url-test":
					clampYAMLInt(group, "timeout", timeout, timeout)
					ensureYAMLString(group, "expected-status", defaultExpectedStatus)
					clampYAMLInt(group, "interval", optimalHealthCheckInterval, optimalHealthCheckInterval)
					clampYAMLInt(group, "tolerance", optimalTolerance, maxAllowedTolerance)
				case "fallback", "load-balance":
					clampYAMLInt(group, "timeout", timeout, timeout)
					ensureYAMLString(group, "expected-status", defaultExpectedStatus)
					clampYAMLInt(group, "interval", optimalHealthCheckInterval, optimalHealthCheckInterval)
				}
			}
		}
	}

	if providers := mappingValue(root, "proxy-providers"); providers != nil {
		forEachMappingEntry(providers, func(name string, value *yaml.Node) {
			provider := resolveAlias(value)
			if provider.Kind != yaml.MappingNode {
				return
			}
			if hcNode := mappingValue(provider, "health-check"); hcNode != nil {
				// Detach/clone to prevent mutating shared alias targets (such as common policy anchors)
				hc := cloneYAMLNode(hcNode)
				if hc.Kind == yaml.MappingNode {
					setMappingValue(provider, "health-check", hc)
					clampYAMLInt(hc, "timeout", timeout, timeout)
					ensureYAMLString(hc, "expected-status", defaultExpectedStatus)
					clampYAMLInt(hc, "interval", optimalHealthCheckInterval, optimalHealthCheckInterval)
				}
			}
		})
	}
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
