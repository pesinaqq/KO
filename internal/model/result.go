package model

import (
	"bytes"
	"encoding/json"
	"strings"
)

// Result 爬虫返回结果。
type Result struct {
	Types     []Type     `json:"class"`
	List      []Vod      `json:"list"`
	Filters   FilterMap  `json:"filters"`
	Header    FlexHeader `json:"header"`
	PlayURL   string     `json:"playUrl"`
	JxFrom    string     `json:"jxFrom"`
	Parse     FlexInt    `json:"parse"`
	Jx        FlexInt    `json:"jx"`
	Flag      string     `json:"flag"`
	Danmaku   FlexString `json:"danmaku"`
	Format    string     `json:"format"`
	URL       URL        `json:"url"`
	Key       string     `json:"key"`
	Click     string     `json:"click"`
	Drm       *Drm       `json:"drm"`
	PageCount FlexInt    `json:"pagecount"`
	Code      FlexInt    `json:"code"`
	Msg       string     `json:"msg"`
	Success   bool       `json:"-"`
}

// Type 分类。
type Type struct {
	TypeID   FlexString `json:"type_id"`
	TypeName string     `json:"type_name"`
	TypeFlag string     `json:"type_flag"`
	Filters  []Filter   `json:"filters,omitempty"`
	Selected bool       `json:"-"`
}

func HomeType() Type {
	return Type{TypeID: "home", TypeName: "推荐", Selected: true}
}

// Filter 筛选条件。
type Filter struct {
	Key   string       `json:"key"`
	Name  string       `json:"name"`
	Init  FlexString   `json:"init"`
	Value []FilterItem `json:"value"`
}

type FilterItem struct {
	N string     `json:"n"`
	V FlexString `json:"v"`
}

// FilterMap 值可为单个 Filter 对象或 Filter 数组。
type FilterMap map[string][]Filter

func (m *FilterMap) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || string(data) == "null" {
 *m = nil
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	out := make(FilterMap, len(raw))
	for k, v := range raw {
		v = bytes.TrimSpace(v)
		if len(v) == 0 || string(v) == "null" {
			continue
		}
		if v[0] == '{' {
			var one Filter
			if err := json.Unmarshal(v, &one); err != nil {
				return err
			}
			out[k] = []Filter{one}
			continue
		}
		var arr []Filter
		if err := json.Unmarshal(v, &arr); err != nil {
			return err
		}
		out[k] = arr
	}
	*m = out
	return nil
}

// URL 播放地址（支持单地址、字符串数组，或交替 name/url 数组）。
type URL struct {
	URLs  []string
	Names []string
}

func (u *URL) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || string(data) == "null" {
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		u.URLs = []string{s}
		return nil
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return nil
	}
	// 交替 name/url：["线路1","http://a","线路2","http://b"]
	if len(arr) >= 2 && len(arr)%2 == 0 {
		var names, urls []string
		ok := true
		for i := 0; i+1 < len(arr); i += 2 {
			var n, v string
			if json.Unmarshal(arr[i], &n) != nil || json.Unmarshal(arr[i+1], &v) != nil {
				ok = false
				break
			}
			names = append(names, n)
			urls = append(urls, v)
		}
		if ok {
 // 若第二项看起来像 URL，按交替解析；否则退回纯字符串数组
			if looksLikePlayURL(urls[0]) || !looksLikePlayURL(names[0]) {
				u.Names = names
				u.URLs = urls
				return nil
			}
		}
	}
	var strs []string
	if err := json.Unmarshal(data, &strs); err == nil {
		u.URLs = strs
	}
	return nil
}

func looksLikePlayURL(s string) bool {
	s = strings.TrimSpace(strings.ToLower(s))
	return strings.HasPrefix(s, "http://") ||
		strings.HasPrefix(s, "https://") ||
		strings.HasPrefix(s, "magnet:") ||
		strings.Contains(s, ".m3u8") ||
		strings.Contains(s, ".mp4")
}

// DecodeResultJSON 反序列化 JSON Result。
func DecodeResultJSON(raw string) (Result, error) {
	var result Result
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return Result{}, err
	}
	return result, nil
}

// Collect 搜索结果分组。
type Collect struct {
	Name      string
	Site      *Site
	List      []Vod
	Activated bool
}

func CollectAll() Collect {
	return Collect{Name: "全部", Activated: true}
}
