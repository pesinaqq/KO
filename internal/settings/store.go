package settings

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"runtime"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/paths"
)

// Type 设置项类型。
type Type string

const (
	VOD                Type = "vod"
	LIVE               Type = "live"
	LOG                Type = "log"
	Player             Type = "player"     // 点播播放器
	PlayerLive         Type = "playerLive" // 直播播放器（与点播独立）
	PopupPlayer        Type = "popupPlayer" // 桌面端独立播放窗口开关（true=独立窗口 / false=内嵌）
	Proxy              Type = "proxy"
	Theme              Type = "theme"
	AdFilter           Type = "adFilter"
	M3U8Cfg            Type = "m3u8FilterConfig"
	DanmakuOn          Type = "danmaku"
	DanmakuAPI         Type = "danmakuApi"
	DanmakuSize        Type = "danmakuSize"
	DanmakuOpacity     Type = "danmakuOpacity"
	DanmakuRows        Type = "danmakuRows"
	AssrtToken         Type = "assrtToken"
	PreferredParse     Type = "preferredParse"
	PlayerSpeed        Type = "playerSpeed"
	PlayerScale        Type = "playerScale"
	PlayerDecode       Type = "playerDecode"
	PlayerFailover     Type = "playerFailover" // 黑屏/停滞自动切换播放器：auto | off
	PlayerVolume       Type = "playerVolume"
	PlayerAmbient      Type = "playerAmbient"
	PlayerStableVolume Type = "playerStableVolume"
	UA                 Type = "ua" // 播放 User-Agent；空则用 Media3 默认
	// MPV：mpv_vulkan / mpv_gpu_next + 自定义 mpv.conf
	MpvVulkan     Type = "mpvVulkan"
	MpvGpuNext    Type = "mpvGpuNext"
	MpvConf       Type = "mpvConf"
	LiveKeep      Type = "liveKeep"     // 上次直播：源$$$分组$$$频道$$$线路URL
	LiveAcross    Type = "liveAcross"   // 跨分组换台，默认 true
	LiveChange    Type = "liveChange"   // 播放失败自动换线，默认 true
	LiveInvert    Type = "liveInvert"   // 反转上下换台方向，默认 false
	DLNARenderer  Type = "dlnaRenderer" // 作为 DLNA 被投端，默认 false
	UpdateURL     Type = "updateUrl"
	AvatarPath    Type = "avatarPath"
	WallMode      Type = "wallMode"
	WallURL       Type = "wallURL"
	WallFile      Type = "wallFile"
	Incognito     Type = "incognito"
	SyncPairCode  Type = "syncPairCode"
	DeviceUUID    Type = "deviceUUID"
	RemoteAuth    Type = "remoteAuth"    // 远端强制登录，默认 false
	AllowRegister Type = "allowRegister" // 开放注册，默认 false
)

type item struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Value string `json:"value"`
}

type file struct {
	List  []item                     `json:"list"`
	Cache map[string]json.RawMessage `json:"cache"`
}

var (
	mu   sync.RWMutex
	data = defaultFile()
)

func defaultFile() file {
	return file{
		List: []item{
			{ID: "vod", Label: "点播", Value: ""},
			{ID: "live", Label: "直播", Value: ""},
			{ID: "log", Label: "日志级别", Value: "info"},
			{ID: "player", Label: "点播播放器", Value: defaultVodPlayerValue()},
			{ID: "playerLive", Label: "直播播放器", Value: defaultLivePlayerValue()},
			{ID: "popupPlayer", Label: "独立播放窗口", Value: "true"},
			{ID: "proxy", Label: "代理", Value: "false#"},
			{ID: "theme", Label: "主题", Value: "system"},
			{ID: "adFilter", Label: "M3U8广告过滤", Value: "true"},
			{ID: "m3u8FilterConfig", Label: "M3U8过滤配置(smart|mild)", Value: "{\"mode\":\"smart\"}"},
			{ID: "danmaku", Label: "弹幕", Value: "true"},
			{ID: "danmakuApi", Label: "弹幕API", Value: ""},
			{ID: "danmakuSize", Label: "弹幕字号", Value: "18"},
			{ID: "danmakuOpacity", Label: "弹幕透明度", Value: "85"},
			{ID: "danmakuRows", Label: "弹幕行数", Value: "6"},
			{ID: "assrtToken", Label: "Assrt字幕Token", Value: ""},
			{ID: "playerSpeed", Label: "默认倍速", Value: "1.0"},
			{ID: "playerScale", Label: "画面比例", Value: "default"},
			{ID: "playerDecode", Label: "解码方式", Value: "auto"},
			{ID: "playerFailover", Label: "自动切换播放器", Value: "auto"},
			{ID: "playerVolume", Label: "默认音量", Value: "80"},
			{ID: "playerAmbient", Label: "氛围模式", Value: "false"},
			{ID: "playerStableVolume", Label: "稳定音量", Value: "false"},
			{ID: "ua", Label: "User-Agent", Value: ""},
			{ID: "mpvVulkan", Label: "MPV Vulkan", Value: "false"},
			{ID: "mpvGpuNext", Label: "MPV gpu-next", Value: "false"},
			{ID: "mpvConf", Label: "MPV 配置", Value: ""},
			{ID: "liveKeep", Label: "上次直播", Value: ""},
			{ID: "liveAcross", Label: "跨组换台", Value: "true"},
			{ID: "liveChange", Label: "失败换线", Value: "true"},
			{ID: "liveInvert", Label: "反转换台", Value: "false"},
			{ID: "dlnaRenderer", Label: "DLNA被投端", Value: "false"},
			{ID: "updateUrl", Label: "更新地址", Value: ""},
			{ID: "avatarPath", Label: "头像", Value: ""},
			{ID: "wallMode", Label: "壁纸模式", Value: "config"},
			{ID: "wallURL", Label: "壁纸 URL", Value: ""},
			{ID: "wallFile", Label: "壁纸文件", Value: ""},
			{ID: "incognito", Label: "无痕模式", Value: "false"},
			{ID: "syncPairCode", Label: "同步配对码", Value: ""},
			{ID: "deviceUUID", Label: "设备标识", Value: ""},
			{ID: "remoteAuth", Label: "远端鉴权", Value: "false"},
			{ID: "allowRegister", Label: "开放注册", Value: "false"},
		},
		Cache: make(map[string]json.RawMessage),
	}
}

func defaultVodPlayerValue() string {
	if runtime.GOOS == "android" {
		return "innie#exo"
	}
	return "innie#mpv"
}

func defaultLivePlayerValue() string {
	if runtime.GOOS == "android" {
		return "innie#exo"
	}
	if runtime.GOOS == "windows" {
		return "innie#mpv"
	}
	return "innie#mpv"
}

// ResolvePlayerLive 直播播放器；空则平台默认。
func ResolvePlayerLive() string {
	v := strings.TrimSpace(Get(PlayerLive))
	if v != "" {
		return v
	}
	return defaultLivePlayerValue()
}

// ResolvePlayerVod 点播播放器。
func ResolvePlayerVod() string {
	v := strings.TrimSpace(Get(Player))
	if v != "" {
		return v
	}
	return defaultVodPlayerValue()
}

// Load 从 setting.ini 加载设置。
func Load() error {
	mu.Lock()
	defer mu.Unlock()
	b, err := os.ReadFile(paths.Setting())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if err := json.Unmarshal(b, &data); err != nil {
		return err
	}
	ensureSettingLocked(PlayerLive, "直播播放器", defaultLivePlayerValue())
	ensureSettingLocked(PlayerFailover, "自动切换播放器", "auto")
	ensureSettingLocked(RemoteAuth, "远端鉴权", "false")
	ensureSettingLocked(AllowRegister, "开放注册", "false")
	return nil
}

func ensureSettingLocked(t Type, label, def string) {
	for _, it := range data.List {
		if it.ID == string(t) {
			return
		}
	}
	data.List = append(data.List, item{ID: string(t), Label: label, Value: def})
}

// Save 持久化设置。
func Save() error {
	mu.RLock()
	defer mu.RUnlock()
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(paths.Setting(), b, 0o644)
}

// Get 获取设置值。
func Get(t Type) string {
	mu.RLock()
	defer mu.RUnlock()
	for _, it := range data.List {
		if it.ID == string(t) {
			return it.Value
		}
	}
	return ""
}

// DefaultPlayUA 未配置 ua 时的播放缺省 User-Agent（Media3 Util.getUserAgent(applicationId) 格式）。
const DefaultPlayUA = "com.bobo.kotv/0.1.0 (Linux;Android 13) ExoPlayerLib/1.4.1"

// PlayUA 播放 User-Agent：设置 ua 非空则用之，否则 DefaultPlayUA。
func PlayUA() string {
	if v := strings.TrimSpace(Get(UA)); v != "" {
		return v
	}
	return DefaultPlayUA
}

// Set 设置值。
func Set(t Type, value string) {
	mu.Lock()
	defer mu.Unlock()
	for i := range data.List {
		if data.List[i].ID == string(t) {
			data.List[i].Value = value
			return
		}
	}
	data.List = append(data.List, item{ID: string(t), Label: string(t), Value: value})
}

// IsAdFilterEnabled M3U8 广告过滤开关。
func IsAdFilterEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(Get(AdFilter)))
	return v == "" || v == "true" || v == "1" || v == "on"
}

// IsDanmakuEnabled 弹幕开关。
func IsDanmakuEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(Get(DanmakuOn)))
	return v == "" || v == "true" || v == "1" || v == "on"
}

// IsLiveAcross 跨分组换台（默认开）。
func IsLiveAcross() bool { return boolSetting(LiveAcross, true) }

// IsLiveChange 播放失败自动换线（默认开）。
func IsLiveChange() bool { return boolSetting(LiveChange, true) }

// IsLiveInvert 反转上下换台方向（默认关）。
func IsLiveInvert() bool { return boolSetting(LiveInvert, false) }

func boolSetting(t Type, def bool) bool {
	v := strings.ToLower(strings.TrimSpace(Get(t)))
	if v == "" {
		return def
	}
	return v == "true" || v == "1" || v == "on"
}

func SetBool(t Type, on bool) {
	if on {
		Set(t, "true")
	} else {
		Set(t, "false")
	}
}

// GetM3U8FilterConfigJSON 返回原始 JSON 配置。
func GetM3U8FilterConfigJSON() string {
	return Get(M3U8Cfg)
}

// SearchHistory 搜索历史。
type SearchHistory struct {
	Items []string `json:"items"`
}

func GetSearchHistory() []string {
	mu.RLock()
	defer mu.RUnlock()
	raw, ok := data.Cache["searchHistory"]
	if !ok {
		return nil
	}
	var h SearchHistory
	if json.Unmarshal(raw, &h) == nil {
		out := make([]string, len(h.Items))
		copy(out, h.Items)
		for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
			out[i], out[j] = out[j], out[i]
		}
		return out
	}
	return nil
}

// IsIncognito 无痕模式：不写观看历史。
func IsIncognito() bool { return boolSetting(Incognito, false) }

// IsDLNARenderer 是否作为局域网 DLNA 被投端。
func IsDLNARenderer() bool { return boolSetting(DLNARenderer, false) }

// Entry 设置项快照（备份/恢复）。
type Entry struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Value string `json:"value"`
}

// ListEntries 返回当前设置列表副本。
func ListEntries() []Entry {
	mu.RLock()
	defer mu.RUnlock()
	out := make([]Entry, len(data.List))
	for i, it := range data.List {
		out[i] = Entry{ID: it.ID, Label: it.Label, Value: it.Value}
	}
	return out
}

// ReplaceEntries 事务性替换设置列表（保留 cache）。
func ReplaceEntries(entries []Entry) {
	mu.Lock()
	defer mu.Unlock()
	data.List = make([]item, len(entries))
	for i, e := range entries {
		data.List[i] = item{ID: e.ID, Label: e.Label, Value: e.Value}
	}
}

// EnsureDeviceUUID 确保设备 UUID 存在。
func EnsureDeviceUUID() string {
	if v := strings.TrimSpace(Get(DeviceUUID)); v != "" {
		return v
	}
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
	Set(DeviceUUID, uuid)
	_ = Save()
	return uuid
}

// EnsureSyncPairCode 确保配对码存在（6 位数字）。
func EnsureSyncPairCode() string {
	if v := strings.TrimSpace(Get(SyncPairCode)); len(v) == 6 {
		return v
	}
	return ResetSyncPairCode()
}

// ResetSyncPairCode 重新生成配对码。
func ResetSyncPairCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(900000))
	code := fmt.Sprintf("%06d", n.Int64()+100000)
	Set(SyncPairCode, code)
	_ = Save()
	return code
}

func AddSearchHistory(q string) {
	mu.Lock()
	defer mu.Unlock()
	var h SearchHistory
	if raw, ok := data.Cache["searchHistory"]; ok {
		_ = json.Unmarshal(raw, &h)
	}
	for i, v := range h.Items {
		if v == q {
			h.Items = append(h.Items[:i], h.Items[i+1:]...)
			break
		}
	}
	h.Items = append(h.Items, q)
	if len(h.Items) > 30 {
		h.Items = h.Items[len(h.Items)-30:]
	}
	b, _ := json.Marshal(h)
	data.Cache["searchHistory"] = b
}
