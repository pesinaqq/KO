package app

import (
	"context"
	"fmt"
	"net/url"
	"path"
	"runtime"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/clientsession"
	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/live"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/player"
	"github.com/bobo/KOTV/internal/player/embed"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/remote"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/service"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
	"github.com/bobo/KOTV/internal/update"
	"github.com/bobo/KOTV/internal/util"
)

// --- ContentAPI（Flutter /api/v1）---

func (a *App) APIHealth() map[string]any {
	_, _, sess := a.scope()
	ready, errMsg := a.Ready, a.ErrMsg
	source := settings.Get(settings.VOD)
	if sess != nil {
		ready, errMsg = sess.Ready, sess.ErrMsg
		source = sess.Source
	}
	spiderOk, spiderErr := spider.HostSpiderReady()
	return map[string]any{
		"ok":            true,
		"engine":        "kotv",
		"platform":      runtime.GOOS,
		"ready":         ready,
		"error":         errMsg,
		"source":        strings.TrimSpace(source),
		"port":          a.Server.Port(),
		"version":       "0.1.0",
		"remoteAuth":    strings.EqualFold(settings.Get(settings.RemoteAuth), "true"),
		"allowRegister": strings.EqualFold(settings.Get(settings.AllowRegister), "true"),
		"spiderOk":      spiderOk,
		"spiderError":   spiderErr,
		"hostRole":      "full", // 对外仅 9978；安卓对内仍可有本机 9979
	}
}

func (a *App) APIGetConfig() map[string]any {
	cfg, _, sess := a.scope()
	ready, errMsg := a.Ready, a.ErrMsg
	source := settings.Get(settings.VOD)
	if sess != nil {
		ready, errMsg = sess.Ready, sess.ErrMsg
		source = sess.Source
	}
	home := cfg.Home()
	sites := make([]map[string]any, 0)
	for _, s := range cfg.Sites() {
		sites = append(sites, map[string]any{
			"key":        s.Key,
			"name":       s.Name,
			"type":       s.TypeID(),
			"searchable": s.IsSearchable(),
			"changeable": s.IsChangeable(),
			"home":       s.Key == home.Key,
		})
	}
	return map[string]any{
		"ok":        true,
		"ready":     ready,
		"error":     errMsg,
		"source":    source,
		"home":      home.Key,
		"sites":     sites,
		"wallpaper": strings.TrimSpace(cfg.API().Wallpaper),
		"logo":      strings.TrimSpace(cfg.API().Logo),
		"banner":    strings.TrimSpace(cfg.API().Banner),
	}
}

func (a *App) APILoadConfig(source string) error {
	cfg, sites, sess := a.scope()
	// 先解析新源；失败则保留旧配置与 Ready，避免首页一直转圈。
	err := cfg.LoadFromSource(source)
	if err != nil {
		return err
	}
	// 新源已进内存后再硬杀旧运行时（本机共享 / 远端该用户）；脚本磁盘缓存保留。
	sites.InvalidateLoads()
	if sess != nil {
		sess.Ready = true
		sess.ErrMsg = ""
		if u := strings.TrimSpace(cfg.API().URL); u != "" {
			sess.Source = u
		} else {
			sess.Source = strings.TrimSpace(source)
		}
		if sess.Live != nil {
			sess.Live.SyncFromConfig()
		}
		clientsession.SaveSource(sess.ClientID, sess.Source, cfg.Home().Key)
	} else {
		a.Ready = true
		a.ErrMsg = ""
		a.Live.SyncFromConfig()
	}
	return nil
}

func (a *App) APISetHome(siteKey string) error {
	cfg, sites, sess := a.scope()
	site := cfg.GetSite(siteKey)
	if site == nil {
		return fmt.Errorf("站点不存在: %s", siteKey)
	}
	sites.InvalidateHomeOnly()
	cfg.SetHome(*site)
	if sess != nil {
		clientsession.SaveSource(sess.ClientID, sess.Source, site.Key)
	}
	return nil
}

func (a *App) APIHome() (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	cfg, sites, _ := a.scope()
	res, err := sites.HomeContent()
	if err != nil {
		return nil, err
	}
	home := cfg.Home()
	return map[string]any{
		"ok":    true,
		"site":  home.Key,
		"class": typesDTO(res.Types),
		"list":  vodsDTO(res.List, home.Key),
	}, nil
}

func (a *App) APICategory(tid, pg string, extend map[string]string) (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	cfg, sites, _ := a.scope()
	res, err := sites.CategoryContent(tid, pg, extend)
	if err != nil {
		return nil, err
	}
	home := cfg.Home()
	return map[string]any{
		"ok":        true,
		"site":      home.Key,
		"tid":       tid,
		"pg":        pg,
		"pagecount": res.PageCount.Value,
		"list":      vodsDTO(res.List, home.Key),
		"filters":   filtersDTO(sites.FiltersForCategory(tid)),
	}, nil
}

func (a *App) APIDetail(siteKey, vodID string) (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	cfg, sites, _ := a.scope()
	vod := model.Vod{VodID: model.FlexString(vodID)}
	if siteKey == service.PushAgentKey {
		vod.Site = &model.Site{Key: service.PushAgentKey, Name: "推送"}
	} else if siteKey != "" {
		if site := cfg.GetSite(siteKey); site != nil {
			vod.Site = site
		}
	}
	if vod.Site == nil {
		h := cfg.Home()
		vod.Site = &h
	}
	detail, err := sites.DetailContent(vod)
	if err != nil {
		return nil, err
	}
	detail.SetVodFlags()
	sk := ""
	if detail.Site != nil {
		sk = detail.Site.Key
	}
	return map[string]any{
		"ok":     true,
		"vod":    vodDetailDTO(detail, sk),
		"magnet": thunder.NeedsParse(&detail),
	}, nil
}

// APIDetailExpand 展开磁力/种子为媒体文件列表。
// 优先用客户端传入的 flags / 上次详情缓存，禁止再次 DetailContent（会重跑爬虫并冲掉扫码弹窗）。
func (a *App) APIDetailExpand(siteKey, vodID string, flagsIn []map[string]any) (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	cfg, sites, _ := a.scope()
	sk := siteKey
	detail := model.Vod{VodID: model.FlexString(vodID)}
	if siteKey != "" {
		if site := cfg.GetSite(siteKey); site != nil {
			detail.Site = site
			sk = site.Key
		}
	}
	if detail.Site == nil {
		h := cfg.Home()
		detail.Site = &h
		if sk == "" {
			sk = h.Key
		}
	}

	if len(flagsIn) > 0 {
		detail.VodFlags = flagsFromDTO(flagsIn)
		detail.VodName = vodID
	} else if cached, ok := sites.CachedDetail(vodID); ok {
		detail = cached
		if detail.Site != nil && detail.Site.Key != "" {
			sk = detail.Site.Key
		}
	} else {
		// 无缓存且客户端未传 flags：不再二次拉详情（避免冲弹窗）；直接返回未展开。
		return map[string]any{
			"ok":       true,
			"expanded": false,
			"magnet":   false,
			"vod":      vodDetailDTO(detail, sk),
			"message":  "无详情缓存，跳过展开",
		}, nil
	}
	detail.SetVodFlags()
	if !thunder.NeedsParse(&detail) {
		return map[string]any{
			"ok":       true,
			"expanded": false,
			"magnet":   false,
			"vod":      vodDetailDTO(detail, sk),
		}, nil
	}
	work := detail
	work.VodFlags = thunder.CloneFlags(detail.VodFlags)
	thunder.SetExpandProgress("正在展开磁力文件列表…")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	thunder.ParseVodContext(ctx, &work)
	thunder.SetExpandProgress("磁力文件列表已更新")
	return map[string]any{
		"ok":       true,
		"expanded": true,
		"magnet":   true,
		"vod":      vodDetailDTO(work, sk),
	}, nil
}

// APIBtProgress 磁力 Fetch/展开进度（Flutter 轮询）。
func (a *App) APIBtProgress() map[string]any {
	p := thunder.CurrentProgress()
	return map[string]any{
		"ok":      true,
		"phase":   p.Phase,
		"peers":   p.Peers,
		"bytes":   p.Bytes,
		"need":    p.Need,
		"message": p.Message,
	}
}

// APICancelPending 打断进行中的爬虫/磁力。
// opts:
//   - hard: true 时硬杀当前所属 JVM/Py/JS；false 仅软取消当前 Scope 请求
//   - thunder: true 时 Stop 磁力 Fetch（会把进度置为「已取消」）；非磁力起播应传 false
func (a *App) APICancelPending(opts map[string]any) map[string]any {
	_, sites, _ := a.scope()
	hard := optBool(opts, "hard", false)
	stopThunder := optBool(opts, "thunder", true)
	if hard {
		sites.CancelPendingContent()
	} else {
		sites.SoftCancelPending()
	}
	if stopThunder {
		thunder.Stop()
	}
	return map[string]any{"ok": true, "hard": hard, "thunder": stopThunder}
}

func optBool(opts map[string]any, key string, def bool) bool {
	if opts == nil {
		return def
	}
	v, ok := opts[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case bool:
		return t
	case float64:
		return t != 0
	case string:
		s := strings.TrimSpace(strings.ToLower(t))
		return s == "1" || s == "true" || s == "yes"
	default:
		return def
	}
}

func (a *App) APISessionPing() map[string]any {
	cid := hostclient.ScopeID()
	if a.presence != nil {
		if uid := hostclient.CurrentUserID(); uid != "" {
			a.presence.Ping(uid)
		}
	}
	return map[string]any{"ok": true, "scopeId": cid, "userId": hostclient.CurrentUserID()}
}

func (a *App) APISessionLeave() map[string]any {
	sid := hostclient.ScopeID()
	uid := hostclient.CurrentUserID()
	if sid != "" {
		a.sessions.Remove(sid)
	}
	if a.presence != nil && uid != "" {
		a.presence.Leave(uid) // KillUserRuntime + CancelUserSniffs + RemoveByUser
	} else if uid != "" {
		spider.KillUserRuntime(uid)
		parse.CancelUserSniffs(uid)
		a.sessions.RemoveByUser(uid)
	}
	return map[string]any{"ok": true}
}

func (a *App) APISearch(keyword string, siteKeys []string) (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	_, sites, _ := a.scope()
	settings.AddSearchHistory(keyword)
	cols, err := sites.SearchParallel(keyword, siteKeys, 4)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(cols))
	flat := make([]map[string]any, 0)
	for _, c := range cols {
		if c.Name == "全部" {
			continue
		}
		sk := ""
		if c.Site != nil {
			sk = c.Site.Key
		}
		list := vodsDTO(c.List, sk)
		out = append(out, map[string]any{
			"site": sk,
			"name": c.Name,
			"list": list,
		})
		flat = append(flat, list...)
	}
	return map[string]any{"ok": true, "keyword": keyword, "collects": out, "list": flat}, nil
}

func (a *App) APIPlay(siteKey, vodID, flag, episodeURL string, qualIdx int) (map[string]any, error) {
	cfg, sites, _ := a.scope()
	var site model.Site
	if siteKey != "" {
		if s := cfg.GetSite(siteKey); s != nil {
			site = *s
		} else if siteKey == service.PushAgentKey {
			site = model.Site{Key: service.PushAgentKey, Name: "推送"}
		}
	}
	if site.Key == "" {
		site = cfg.Home()
	}
	epURL := strings.TrimSpace(episodeURL)
	if epURL == "" {
		return nil, fmt.Errorf("empty episode url")
	}
	// iOS 仅支持前端播放链路：允许直链/磁力，不走站点解析。
	if localCrawlerDisabled() && !(strings.HasPrefix(epURL, "http") && parse.IsVideoFormat(epURL)) && !thunder.Match(epURL) {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}

	var playURL string
	var headers map[string]string
	var danmakuURL string
	var qualNames, qualURLs []string
	var playDrm *model.Drm
	var didParse bool

	// 一律先 SiteApi.playerContent（含站点 Header/PlayURL/parse），再 Source.fetch / ParseJob。
	// 仅磁力可先占位，真正取流仍在后面 thunder.Fetch。
	if thunder.Match(epURL) {
		playURL = epURL
	} else {
		result, err := sites.PlayerContent(site, flag, epURL)
		if err != nil {
			return nil, err
		}
		if runtime.GOOS != "android" {
			if err := result.Drm.DesktopError(); err != nil {
				return nil, err
			}
		}
		playDrm = result.Drm
		headers = map[string]string(result.Header)
		danmakuURL = result.Danmaku
		qualNames = result.URL.Names
		qualURLs = result.URL.URLs
		api := cfg.API()
		rules := parse.GetRules()
		if len(rules) == 0 {
			rules = api.Rules
		}
		// 对齐 TV：仅 needParse / useParse 时才进 ParseJob；直链跳过。
		didParse = parse.NeedParse(result) || parse.IsUseParse(result, api.Flags, api.Parses)
		parsed, perr := parse.ResolveWithParses(result, parse.Options{
			Parses:    api.Parses,
			Flags:     api.Flags,
			Rules:     rules,
			Jar:       api.Spider,
			Flag:      flag,
			Click:     result.Click,
			SiteClick: site.Click,
			Prefer:    settings.Get(settings.PreferredParse),
			IsVideo: func(u string) bool {
				return sites.IsVideoFormat(site, u)
			},
		})
		if perr != nil {
			cand := apiResolvePlayURL("", result.PlayURL, result.URL.URLs, qualIdx)
			if cand != "" && (parse.IsVideoFormat(cand) || thunder.Match(cand)) {
				playURL = cand
				didParse = false
			} else {
				return nil, parse.AnnotateParseErr(perr)
			}
		} else {
			result = parsed
			if runtime.GOOS != "android" {
				if err := result.Drm.DesktopError(); err != nil {
					return nil, err
				}
			}
			if result.Drm != nil {
				playDrm = result.Drm
			}
			headers = mergeStringMaps(headers, map[string]string(result.Header))
			qualNames = result.URL.Names
			qualURLs = result.URL.URLs
			playURL = apiResolvePlayURL("", result.PlayURL, result.URL.URLs, qualIdx)
			if result.Danmaku != "" {
				danmakuURL = result.Danmaku
			}
		}
	}

	if playURL == "" {
		return nil, fmt.Errorf("未获取到播放地址")
	}
	if apiLooksUnplayable(playURL) {
		return nil, fmt.Errorf("未解析到可播放地址")
	}

	mediaURL := playURL
	magnet := thunder.Match(playURL)
	if magnet {
		// 起播前 Source.stop，确保可被 cancelPending / 换集打断
		thunder.Stop()
		local, err := thunder.Fetch(playURL)
		if err != nil {
			return nil, fmt.Errorf("磁力链接解析失败: %w", err)
		}
		playURL = local
	} else if !thunder.IsLocalStream(playURL) {
		playURL = a.PreparePlaybackURL(playURL, headers)
	}
	isMagnetPlay := magnet || thunder.IsLocalStream(playURL)

	title := vodID
	a.SetMediaPlaying(title, playURL)

	return map[string]any{
		"ok":        true,
		"url":       playproxy.PublicizeURL(playURL),
		"media":     mediaURL,
		"magnet":    isMagnetPlay,
		"parsed":    didParse,
		"headers":   headers,
		"drm":       playDrm,
		"danmaku":   danmakuURL,
		"qualities": map[string]any{"names": qualNames, "urls": qualURLs},
		"site":      site.Key,
		"flag":      flag,
		"id":        vodID,
	}, nil
}

func typesDTO(types []model.Type) []map[string]any {
	out := make([]map[string]any, 0, len(types))
	for _, t := range types {
		out = append(out, map[string]any{
			"type_id":   t.TypeID.String(),
			"type_name": t.TypeName,
			"filters":   filtersDTO(t.Filters),
		})
	}
	return out
}

func filtersDTO(filters []model.Filter) []map[string]any {
	out := make([]map[string]any, 0, len(filters))
	for _, f := range filters {
		vals := make([]map[string]any, 0, len(f.Value))
		for _, it := range f.Value {
			vals = append(vals, map[string]any{"n": it.N, "v": it.V.String()})
		}
		out = append(out, map[string]any{
			"key":   f.Key,
			"name":  f.Name,
			"init":  f.Init.String(),
			"value": vals,
		})
	}
	return out
}

func vodsDTO(list []model.Vod, siteKey string) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, v := range list {
		sk := siteKey
		if v.Site != nil && v.Site.Key != "" {
			sk = v.Site.Key
		}
		out = append(out, map[string]any{
			"vod_id":      v.VodID.String(),
			"vod_name":    v.VodName,
			"vod_pic":     v.VodPic,
			"vod_remarks": v.VodRemarks,
			"type_name":   v.TypeName,
			"site":        sk,
			"action":      v.Action,
			"vod_tag":     v.VodTag,
		})
	}
	return out
}

func vodDetailDTO(v model.Vod, siteKey string) map[string]any {
	flags := make([]map[string]any, 0, len(v.VodFlags))
	for _, f := range v.VodFlags {
		eps := make([]map[string]any, 0, len(f.Episodes))
		for _, ep := range f.Episodes {
			eps = append(eps, map[string]any{
				"name": ep.Name,
				"url":  ep.URL,
			})
		}
		show := f.Show
		if show == "" {
			show = f.Flag
		}
		flags = append(flags, map[string]any{
			"flag":     f.Flag,
			"show":     show,
			"episodes": eps,
		})
	}
	return map[string]any{
		"vod_id":       v.VodID.String(),
		"vod_name":     v.VodName,
		"vod_pic":      v.VodPic,
		"vod_remarks":  v.VodRemarks,
		"vod_year":     v.VodYear.String(),
		"vod_area":     v.VodArea,
		"vod_director": v.VodDirector,
		"vod_actor":    v.VodActor,
		"vod_content":  v.VodContent,
		"type_name":    v.TypeName,
		"site":         siteKey,
		"flags":        flags,
	}
}

func flagsFromDTO(in []map[string]any) []model.Flag {
	out := make([]model.Flag, 0, len(in))
	for _, m := range in {
		flag := strings.TrimSpace(fmt.Sprint(m["flag"]))
		show := strings.TrimSpace(fmt.Sprint(m["show"]))
		if show == "" {
			show = flag
		}
		var eps []model.Episode
		rawEps, _ := m["episodes"].([]any)
		for _, e := range rawEps {
			em, ok := e.(map[string]any)
			if !ok {
				continue
			}
			name := strings.TrimSpace(fmt.Sprint(em["name"]))
			u := strings.TrimSpace(fmt.Sprint(em["url"]))
			if u == "" {
				continue
			}
			if name == "" {
				name = u
			}
			eps = append(eps, model.Episode{Name: name, URL: u})
		}
		out = append(out, model.Flag{Flag: flag, Show: show, Episodes: eps})
	}
	return out
}

func apiResolvePlayURL(raw, playURL string, urls []string, idx int) string {
	if idx < 0 {
		idx = 0
	}
	pick := func(u string) string {
		u = strings.TrimSpace(u)
		if strings.HasPrefix(strings.ToLower(u), "video://") {
			u = strings.TrimSpace(u[len("video://"):])
		}
		if playURL != "" && !strings.HasPrefix(u, "http") && !strings.HasPrefix(u, "magnet:") {
			return playURL + u
		}
		return u
	}
	if idx < len(urls) && strings.TrimSpace(urls[idx]) != "" {
		return pick(urls[idx])
	}
	if len(urls) > 0 && strings.TrimSpace(urls[0]) != "" {
		return pick(urls[0])
	}
	if strings.TrimSpace(raw) != "" {
		return pick(raw)
	}
	return pick(playURL)
}

func apiLooksUnplayable(u string) bool {
	u = strings.TrimSpace(u)
	if u == "" {
		return true
	}
	low := strings.ToLower(u)
	if strings.HasPrefix(low, "http://") || strings.HasPrefix(low, "https://") {
		if strings.Contains(low, "player/?url=") && !parse.IsVideoFormat(u) && !thunder.Match(u) {
			return true
		}
		if strings.Contains(low, ".html") || strings.HasSuffix(low, "/") {
			ext := path.Ext(u)
			if ext == "" || ext == ".html" || ext == ".htm" || ext == ".php" {
				if !parse.IsVideoFormat(u) && !thunder.Match(u) {
					return true
				}
			}
		}
		return false
	}
	if thunder.Match(u) {
		return false
	}
	if _, err := url.Parse(u); err == nil && strings.HasPrefix(u, "/") {
		return true
	}
	return !parse.IsVideoFormat(u)
}

func mergeStringMaps(a, b map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func (a *App) APIRemotePoll() map[string]any {
	ctrls, searches := remote.DefaultQueue.Drain(hostclient.ScopeID())
	outCtrl := make([]map[string]any, 0, len(ctrls))
	for _, c := range ctrls {
		outCtrl = append(outCtrl, map[string]any{"type": c.Type, "seekMs": c.SeekMs})
	}
	return map[string]any{
		"ok":       true,
		"controls": outCtrl,
		"searches": searches,
	}
}

func (a *App) APISetMedia(state map[string]string) {
	_, _, sess := a.scope()
	if sess != nil {
		sess.SetMediaSnapshot(state)
	}
	remote.SetMediaStore(state)
}

func (a *App) APIListRepos() map[string]any {
	cfgs, _ := a.DB.ListConfigs(int64(database.ConfigTypeSite))
	_, _, sess := a.scope()
	current := strings.TrimSpace(settings.Get(settings.VOD))
	if sess != nil {
		current = strings.TrimSpace(sess.Source)
	}
	list := make([]map[string]any, 0, len(cfgs))
	for _, c := range cfgs {
		url := strings.TrimSpace(c.URL)
		if url == "" {
			continue
		}
		name := config.ConfigLabel(c.Name, url)
		list = append(list, map[string]any{
			"url":     url,
			"name":    name,
			"title":   strings.TrimSpace(c.Name),
			"home":    c.Home,
			"current": url == current,
		})
	}
	return map[string]any{"ok": true, "current": current, "repos": list}
}

func (a *App) APIDeleteRepo(url string) error {
	url = strings.TrimSpace(url)
	if url == "" {
		return fmt.Errorf("empty url")
	}
	return a.DB.DeleteConfigByURL(url, int64(database.ConfigTypeSite))
}

// APIEditRepo 编辑点播源名称/地址（对齐 TV 设置页长按 ConfigDialog.edit）。
func (a *App) APIEditRepo(oldURL, newURL, name string) error {
	return a.editConfig(database.ConfigTypeSite, oldURL, newURL, name)
}

func (a *App) APIDeleteLive(url string) error {
	url = strings.TrimSpace(url)
	if url == "" {
		return fmt.Errorf("empty url")
	}
	if err := a.DB.DeleteConfigByURL(url, int64(database.ConfigTypeLive)); err != nil {
		return err
	}
	if strings.TrimSpace(settings.Get(settings.LIVE)) == url {
		settings.Set(settings.LIVE, "")
		_ = settings.Save()
	}
	a.syncLive()
	return nil
}

// APIEditLive 编辑直播源名称/地址。
func (a *App) APIEditLive(oldURL, newURL, name string) error {
	return a.editConfig(database.ConfigTypeLive, oldURL, newURL, name)
}

func (a *App) editConfig(typ int64, oldURL, newURL, name string) error {
	if a.DB == nil {
		return fmt.Errorf("database unavailable")
	}
	oldURL = strings.TrimSpace(oldURL)
	newURL = config.NormalizeSource(strings.TrimSpace(newURL))
	name = strings.TrimSpace(name)
	if newURL == "" {
		return fmt.Errorf("请输入源地址")
	}
	if oldURL == "" {
		oldURL = newURL
	}
	if err := a.DB.UpdateConfigURLName(oldURL, typ, newURL, name); err != nil {
		return err
	}
	// 只改备注名、地址没变：不要整源重载（会卡住，且弹窗列表来不及刷新）。
	if oldURL == newURL {
		return nil
	}
	switch typ {
	case database.ConfigTypeSite:
		_, _, sess := a.scope()
		cur := strings.TrimSpace(settings.Get(settings.VOD))
		if sess != nil {
			cur = strings.TrimSpace(sess.Source)
		}
		if cur == "" || cur == oldURL || cur == newURL {
			return a.APILoadConfig(newURL)
		}
	case database.ConfigTypeLive:
		cur := strings.TrimSpace(settings.Get(settings.LIVE))
		if cur == "" || cur == oldURL || cur == newURL {
			settings.Set(settings.LIVE, newURL)
			_ = settings.Save()
			a.syncLive()
		}
	}
	return nil
}

func (a *App) APIGetSettings() map[string]any {
	cfg, _, sess := a.scope()
	keys := []settings.Type{
		settings.VOD, settings.LIVE, settings.Theme, settings.Player, settings.PlayerLive,
		settings.PopupPlayer,
		settings.PopupPlayer,
		settings.Proxy, settings.PlayerSpeed, settings.PlayerScale, settings.PlayerDecode,
		settings.PlayerFailover,
		settings.PlayerVolume, settings.PlayerAmbient, settings.PlayerStableVolume,
		settings.UA,
		settings.MpvVulkan, settings.MpvGpuNext, settings.MpvConf,
		settings.PreferredParse, settings.AdFilter, settings.M3U8Cfg, settings.DanmakuOn, settings.DanmakuAPI,
		settings.DanmakuSize, settings.DanmakuOpacity, settings.DanmakuRows,
		settings.AssrtToken, settings.UpdateURL, settings.WallMode, settings.WallURL,
		settings.WallFile, settings.Incognito, settings.LiveAcross, settings.LiveChange,
		settings.LiveInvert, settings.DLNARenderer, settings.SyncPairCode, settings.LiveKeep,
	}
	out := map[string]any{"ok": true, "port": a.Server.ProxyPort()}
	vals := map[string]string{}
	for _, k := range keys {
		vals[string(k)] = settings.Get(k)
	}
	if sess != nil {
		vals[string(settings.VOD)] = sess.Source
	}
	settings.OverlayClientProfile(vals, hostclient.CurrentPlatform())
	out["settings"] = vals
	vodURL := strings.TrimSpace(vals[string(settings.VOD)])
	liveURL := strings.TrimSpace(vals[string(settings.LIVE)])
	out["vodDesc"] = a.configDesc(database.ConfigTypeSite, vodURL)
	out["liveDesc"] = a.configDesc(database.ConfigTypeLive, liveURL)
	parses := make([]map[string]any, 0)
	for _, p := range cfg.API().Parses {
		parses = append(parses, map[string]any{"name": p.Name, "type": p.TypeID(), "url": p.URL})
	}
	out["parses"] = parses
	out["version"] = update.CurrentVersion
	out["runtime"] = appruntime.Status()
	out["crawlerEnabled"] = !localCrawlerDisabled()
	out["searchHistory"] = settings.GetSearchHistory()
	out["backdrop"] = a.APIBackdrop()
	out["pairCode"] = settings.EnsureSyncPairCode()
	out["remoteAuth"] = strings.EqualFold(settings.Get(settings.RemoteAuth), "true")
	out["allowRegister"] = strings.EqualFold(settings.Get(settings.AllowRegister), "true")
	return out
}

// APIBackdrop 输出统一背景规格，供 Flutter 背景层使用。
func (a *App) APIBackdrop() map[string]any {
	cfg, _, sess := a.scope()
	ready := a.Ready
	if sess != nil {
		ready = sess.Ready
	}
	mode := strings.TrimSpace(settings.Get(settings.WallMode))
	if mode == "" {
		mode = "config"
	}
	theme := strings.TrimSpace(settings.Get(settings.Theme))
	light := theme == "light"
	// 跟随系统时 Flutter 侧可再判；引擎侧默认按深色出 tint。
	if theme == "system" {
		light = false
	}

	gradStart, gradEnd := "#243DD0", "#B220AC"
	glowTop, glowBot, glowMid := "#35FF55CB", "#3028C9FF", "#288D50F2"
	wallTint := "#55120832"
	if light {
		gradStart, gradEnd = "#E9EEFB", "#F3E7F8"
		glowTop, glowBot, glowMid = "#2EFF8AC8", "#2A7AC8FF", "#24B994F5"
		wallTint = "#73FFFFFF"
	}

	configWall := ""
	if ready {
		configWall = strings.TrimSpace(cfg.API().Wallpaper)
	}
	wallURL := strings.TrimSpace(settings.Get(settings.WallURL))
	wallFile := strings.TrimSpace(settings.Get(settings.WallFile))

	switch mode {
	case "builtin1":
		if light {
			gradStart, gradEnd = "#DDEEFA", "#C8E0F2"
		} else {
			gradStart, gradEnd = "#1A5C8A", "#0E3A5C"
		}
		glowTop, glowBot, glowMid = "#304FC3F7", "#28156B8A", "#252E86AB"
	case "builtin2":
		if light {
			gradStart, gradEnd = "#F7E3F2", "#FBE0E6"
		} else {
			gradStart, gradEnd = "#7B2D8E", "#C73C62"
		}
		glowTop, glowBot, glowMid = "#32FF8A65", "#28E91E63", "#22FF6F91"
	case "builtin3":
		if light {
			gradStart, gradEnd = "#E2EEEE", "#D5E4E8"
		} else {
			gradStart, gradEnd = "#0F202E", "#203A43"
		}
		glowTop, glowBot, glowMid = "#2880CBC4", "#224DA8DA", "#20266E8C"
	}

	// UI 色板：卡片/按钮/字体随壁纸主题变化。
	primary, surface, variant := "#CF4274", "#63248A", "#653AA8"
	fg, muted, outline := "#FFFFFFFF", "#D8FFFFFF", "#B0D8A5E8"
	input, pillBg, pillBorder := "#FF582D91", "#E618161E", "#C84A4855"
	statusBar, catBar, bottomNav := "#60551C72", "#4D653AA8", "#EE1A0F2E"
	dialogBg, posterBar, posterPh := "#FA3B1970", "#CC653AA8", "#FF3A1A6E"
	selected, focus := "#F2C73C62", "#FFFFD54F"
	name := "极光紫"
	switch mode {
	case "builtin1":
		name = "深海蓝"
		if light {
			primary, surface, variant = "#156B8A", "#C8E0F2", "#4FC3F7"
			fg, muted, outline = "#FF0E3A5C", "#CC0E3A5C", "#88156B8A"
			input, pillBg, pillBorder = "#FFE8F4FC", "#E6FFFFFF", "#882E86AB"
			statusBar, catBar, bottomNav = "#99C8E0F2", "#88A8D4E8", "#EEF2F8FC"
			dialogBg, posterBar, posterPh = "#F2E8F4FC", "#CC2E86AB", "#FFB0D4E8"
			selected, focus = "#F22E86AB", "#FF156B8A"
		} else {
			primary, surface, variant = "#4FC3F7", "#156B8A", "#2E86AB"
			fg, muted, outline = "#FFFFFFFF", "#D8FFFFFF", "#904FC3F7"
			input, pillBg, pillBorder = "#FF0E3A5C", "#E60A2438", "#884FC3F7"
			statusBar, catBar, bottomNav = "#600E3A5C", "#4D1A5C8A", "#EE0A1E2E"
			dialogBg, posterBar, posterPh = "#FA0E3A5C", "#CC156B8A", "#FF0E3A5C"
			selected, focus = "#F22E86AB", "#FF4FC3F7"
		}
	case "builtin2":
		name = "绯霞玫"
		if light {
			primary, surface, variant = "#C73C62", "#F7E3F2", "#E86A83"
			fg, muted, outline = "#FF5A1A3A", "#CC5A1A3A", "#88C73C62"
			input, pillBg, pillBorder = "#FFFFF0F5", "#E6FFFFFF", "#88E86A83"
			statusBar, catBar, bottomNav = "#99F7E3F2", "#88F0D0E0", "#EEFFF5F8"
			dialogBg, posterBar, posterPh = "#F2FFF0F5", "#CCC73C62", "#FFE8B0C0"
			selected, focus = "#F2C73C62", "#FFE91E63"
		} else {
			primary, surface, variant = "#FF6F91", "#7B2D8E", "#C73C62"
			fg, muted, outline = "#FFFFFFFF", "#D8FFFFFF", "#B0FF8AA5"
			input, pillBg, pillBorder = "#FF5A2068", "#E61A0C22", "#C8E86A83"
			statusBar, catBar, bottomNav = "#60551C48", "#4D7B2D8E", "#EE1A0A1E"
			dialogBg, posterBar, posterPh = "#FA5A2068", "#CCC73C62", "#FF4A1848"
			selected, focus = "#F2C73C62", "#FFFF8A65"
		}
	case "builtin3":
		name = "墨夜青"
		if light {
			primary, surface, variant = "#266E8C", "#D5E4E8", "#4DA8DA"
			fg, muted, outline = "#FF0F202E", "#CC0F202E", "#88266E8C"
			input, pillBg, pillBorder = "#FFE8F0F2", "#E6FFFFFF", "#884DA8DA"
			statusBar, catBar, bottomNav = "#99D5E4E8", "#88C0D4DA", "#EEF0F4F6"
			dialogBg, posterBar, posterPh = "#F2E8F0F2", "#CC266E8C", "#FFB0C8D0"
			selected, focus = "#F24DA8DA", "#FF266E8C"
		} else {
			primary, surface, variant = "#80CBC4", "#203A43", "#4DA8DA"
			fg, muted, outline = "#FFFFFFFF", "#D8FFFFFF", "#9080CBC4"
			input, pillBg, pillBorder = "#FF152830", "#E60A141C", "#884DA8DA"
			statusBar, catBar, bottomNav = "#600F202E", "#4D203A43", "#EE0A1218"
			dialogBg, posterBar, posterPh = "#FA152830", "#CC203A43", "#FF0F202E"
			selected, focus = "#F24DA8DA", "#FF80CBC4"
		}
	default:
		if mode == "gradient" {
			name = "极光紫"
		} else if mode == "config" {
			name = "配置墙纸"
		} else if mode == "url" {
			name = "网络图片"
		} else if mode == "file" {
			name = "本地文件"
		} else {
			name = "极光紫"
		}
		if light {
			primary, surface, variant = "#1A2A6C", "#E9EEFB", "#B994F5"
			fg, muted, outline = "#FF1B1B24", "#CC45464F", "#88767680"
			input, pillBg, pillBorder = "#FFDDE2FF", "#E6FFFFFF", "#88767680"
			statusBar, catBar, bottomNav = "#99E9EEFB", "#88D8D0F0", "#EEFCF8FF"
			dialogBg, posterBar, posterPh = "#F2FCF8FF", "#CC653AA8", "#FFD0C8E8"
			selected, focus = "#F2C73C62", "#FF1A2A6C"
		}
	}

	image := ""
	switch mode {
	case "url":
		image = wallURL
	case "file":
		image = wallFile
	case "config":
		image = configWall
	case "gradient", "builtin1", "builtin2", "builtin3":
		image = ""
	default:
		if mode == "" {
			image = configWall
		}
	}
	image = a.resolveBackdropImageURL(image)

	// 本地文件走引擎 /file/ 代理，便于 Flutter Image.network 加载。
	if image != "" && !strings.HasPrefix(image, "http://") && !strings.HasPrefix(image, "https://") {
		path := strings.TrimPrefix(image, "file://")
		if path != "" {
			port := a.Server.Port()
			esc := url.PathEscape(path)
			esc = strings.ReplaceAll(esc, "%2F", "/")
			image = fmt.Sprintf("http://127.0.0.1:%d/file/%s", port, esc)
		}
	}

	return map[string]any{
		"mode":       mode,
		"name":       name,
		"light":      light,
		"image":      image,
		"gradStart":  gradStart,
		"gradEnd":    gradEnd,
		"glowTop":    glowTop,
		"glowBottom": glowBot,
		"glowMid":    glowMid,
		"wallTint":   wallTint,
		"wallURL":    wallURL,
		"wallFile":   wallFile,
		"configWall": configWall,
		"primary":    primary,
		"surface":    surface,
		"variant":    variant,
		"fg":         fg,
		"muted":      muted,
		"outline":    outline,
		"input":      input,
		"pillBg":     pillBg,
		"pillBorder": pillBorder,
		"statusBar":  statusBar,
		"catBar":     catBar,
		"bottomNav":  bottomNav,
		"dialogBg":   dialogBg,
		"posterBar":  posterBar,
		"posterPh":   posterPh,
		"selected":   selected,
		"focus":      focus,
	}
}

func (a *App) resolveBackdropImageURL(src string) string {
	src = strings.TrimSpace(src)
	if src == "" {
		return ""
	}
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") || strings.HasPrefix(src, "file://") {
		return src
	}
	// 绝对本地路径原样返回，上层会转 /file/。
	if strings.HasPrefix(src, "/") {
		return src
	}
	cfg, _, sess := a.scope()
	ready := a.Ready
	if sess != nil {
		ready = sess.Ready
	}
	if ready {
		base := strings.TrimSpace(cfg.API().URL)
		if base != "" {
			if resolved := util.ResolveRelativeURL(base, src); resolved != "" {
				return resolved
			}
		}
	}
	return src
}

func (a *App) APISetSettings(kv map[string]string) error {
	needProxy := false
	needLive := false
	needDLNA := false
	kv = settings.SetClientProfileKeys(kv, hostclient.CurrentPlatform())
	for k, v := range kv {
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		t := settings.Type(k)
		if t == settings.LIVE {
			v = a.persistLiveSource(v)
			needLive = true
		}
		settings.Set(t, v)
		if t == settings.Proxy {
			needProxy = true
		}
		if t == settings.DLNARenderer {
			needDLNA = true
		}
	}
	if err := settings.Save(); err != nil {
		return err
	}
	if needProxy {
		util.SetProxy(settings.Get(settings.Proxy))
		spider.SetUserProxy(settings.Get(settings.Proxy))
	}
	if needLive {
		a.syncLive()
	}
	if needDLNA {
		a.SyncDLNARenderer()
	}
	return nil
}

func (a *App) APIToggleSite(key, field string, all *bool) error {
	cfg, _, _ := a.scope()
	field = strings.ToLower(strings.TrimSpace(field))
	if all != nil {
		switch field {
		case "searchable":
			return cfg.SetAllSitesSearchable(*all)
		case "changeable":
			return cfg.SetAllSitesChangeable(*all)
		default:
			return fmt.Errorf("unknown toggle: %s", field)
		}
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return fmt.Errorf("missing key")
	}
	switch field {
	case "searchable":
		_, err := cfg.ToggleSiteSearchable(key)
		return err
	case "changeable":
		_, err := cfg.ToggleSiteChangeable(key)
		return err
	default:
		return fmt.Errorf("unknown toggle: %s", field)
	}
}

func (a *App) configDesc(typ int64, rawURL string) string {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return ""
	}
	name := ""
	if a.DB != nil {
		if c, err := a.DB.FindConfig(rawURL, typ); err == nil && c != nil {
			name = c.Name
		}
	}
	return config.ConfigLabel(name, rawURL)
}

func (a *App) APILiveSources() map[string]any {
	lv := a.scopeLive()
	lv.SyncFromConfig()
	srcs := lv.Sources()
	cfg, _, _ := a.scope()
	vodURL := strings.TrimSpace(cfg.API().URL)
	current := strings.TrimSpace(settings.Get(settings.LIVE))
	if current == "" {
		current = vodURL
	}
	list := make([]map[string]any, 0, len(srcs))
	for i, l := range srcs {
		list = append(list, map[string]any{
			"index": i,
			"name":  config.ConfigLabel(l.Name, l.URL),
			"url":   l.URL,
			"api":   l.API,
		})
	}
	hist := a.savedLiveSources()
	configs := make([]map[string]any, 0, len(hist))
	for _, l := range hist {
		u := strings.TrimSpace(l.URL)
		configs = append(configs, map[string]any{
			"name":    config.ConfigLabel(l.Name, u),
			"title":   strings.TrimSpace(l.Name),
			"url":     u,
			"current": u != "" && u == current,
		})
	}
	return map[string]any{
		"ok":      true,
		"live":    current,
		"sources": list,
		"configs": configs,
	}
}

func (a *App) APILiveLoad(index int, url string) (map[string]any, error) {
	lv := a.scopeLive()
	url = strings.TrimSpace(url)
	if url != "" {
		url = a.persistLiveSource(url)
		settings.Set(settings.LIVE, url)
		_ = settings.Save()
		a.syncLive()
	} else {
		lv.SyncFromConfig()
	}
	srcs := lv.Sources()
	var liveSrc model.Live
	if url != "" {
		if len(srcs) == 0 {
			liveSrc = model.Live{Name: config.ConfigLabel("", url), URL: url}
		} else {
			liveSrc = srcs[0]
			for _, s := range srcs {
				if strings.TrimSpace(s.URL) == url {
					liveSrc = s
					break
				}
			}
		}
	} else {
		if index < 0 || index >= len(srcs) {
			return nil, fmt.Errorf("直播源索引无效")
		}
		liveSrc = srcs[index]
	}
	loaded, err := lv.Load(liveSrc)
	if err != nil {
		return nil, err
	}
	groups := make([]map[string]any, 0, len(loaded.Groups))
	for gi, g := range loaded.Groups {
		chs := make([]map[string]any, 0, len(g.Channels))
		for ci := range g.Channels {
			ch := &loaded.Groups[gi].Channels[ci]
			ch.ApplyLive(loaded)
			chs = append(chs, map[string]any{
				"index": ci,
				"name":  ch.Name,
				"logo":  ch.ResolvedLogo(),
				"tvgId": ch.TvgID,
				"urls":  len(ch.URLs),
				"line":  ch.URLIndex,
			})
		}
		groups = append(groups, map[string]any{
			"index":    gi,
			"name":     g.Name,
			"locked":   g.Pass != "",
			"channels": chs,
		})
	}
	name := strings.TrimSpace(loaded.Name)
	if name == "" {
		name = loaded.URL
	}
	return map[string]any{
		"ok":     true,
		"name":   name,
		"url":    loaded.URL,
		"groups": groups,
	}, nil
}

func (a *App) liveChannelAt(group, channel int) (*model.Live, *model.LiveGroup, *model.LiveChannel, error) {
	lv := a.scopeLive()
	cur := lv.Current()
	if cur == nil || len(cur.Groups) == 0 {
		return nil, nil, nil, fmt.Errorf("请先加载直播源")
	}
	if group < 0 || group >= len(cur.Groups) {
		return nil, nil, nil, fmt.Errorf("分组无效")
	}
	g := &cur.Groups[group]
	if channel < 0 || channel >= len(g.Channels) {
		return nil, nil, nil, fmt.Errorf("频道无效")
	}
	ch := &g.Channels[channel]
	ch.ApplyLive(cur)
	return cur, g, ch, nil
}

func (a *App) APILivePlay(group, channel, line int) (map[string]any, error) {
	lv := a.scopeLive()
	_, g, ch, err := a.liveChannelAt(group, channel)
	if err != nil {
		return nil, err
	}
	if line >= 0 && line < len(ch.URLs) {
		ch.URLIndex = line
	}
	// 对齐 TV：普通频道直取线路 URL；仅 parse/json/video 前缀才二次解析。
	playURL, headers, err := lv.ResolvePlayURLParsed(ch)
	if err != nil && playURL == "" {
		return nil, err
	}
	if playURL == "" {
		return nil, fmt.Errorf("空播放地址")
	}
	return map[string]any{
		"ok":      true,
		"url":     playproxy.PublicizeURL(playURL),
		"headers": headers,
		"name":    ch.Name,
		"group":   g.Name,
		"line":    ch.URLIndex,
		"lines":   len(ch.URLs),
		"error":   errString(err),
	}, nil
}

func (a *App) APILiveUnlock(group int, password string) error {
	cur := a.scopeLive().Current()
	if cur == nil || len(cur.Groups) == 0 {
		return fmt.Errorf("请先加载直播源")
	}
	password = strings.TrimSpace(password)
	if password == "" {
		return fmt.Errorf("请输入密码")
	}
	if group >= 0 && group < len(cur.Groups) {
		if cur.Groups[group].Pass == password {
			return nil
		}
		return fmt.Errorf("分组密码不正确")
	}
	for i := range cur.Groups {
		if cur.Groups[i].Pass == password {
			return nil
		}
	}
	return fmt.Errorf("未找到匹配的分组密码")
}

func (a *App) APILiveEPG(group, channel int) (map[string]any, error) {
	_, _, ch, err := a.liveChannelAt(group, channel)
	if err != nil {
		return nil, err
	}
	epgs := live.LoadChannelDays(ch)
	days := make([]map[string]any, 0, len(epgs))
	for di, day := range epgs {
		progs := make([]map[string]any, 0, len(day.List))
		for pi, p := range day.List {
			progs = append(progs, map[string]any{
				"index":   pi,
				"title":   p.Title,
				"start":   p.Start,
				"end":     p.End,
				"now":     p.IsInRange(),
				"future":  p.IsFuture(),
				"label":   p.Format(),
				"range":   p.Range(),
				"catchup": ch.HasCatchup() && !p.IsFuture() && p.StartTime > 0,
			})
		}
		days = append(days, map[string]any{
			"index": di,
			"date":  day.Date,
			"list":  progs,
		})
	}
	return map[string]any{
		"ok":   true,
		"name": ch.Name,
		"logo": ch.ResolvedLogo(),
		"days": days,
	}, nil
}

func (a *App) APILiveCatchup(group, channel, day, prog int) (map[string]any, error) {
	_, g, ch, err := a.liveChannelAt(group, channel)
	if err != nil {
		return nil, err
	}
	epgs := live.LoadChannelDays(ch)
	if day < 0 || day >= len(epgs) {
		return nil, fmt.Errorf("节目日期无效")
	}
	list := epgs[day].List
	if prog < 0 || prog >= len(list) {
		return nil, fmt.Errorf("节目无效")
	}
	url, headers, err := live.ResolveCatchupURL(a.Live, ch, list[prog])
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"ok":      true,
		"url":     playproxy.PublicizeURL(url),
		"headers": headers,
		"name":    list[prog].Title,
		"group":   g.Name,
		"channel": ch.Name,
	}, nil
}

// APIPlayerStatus 播放器可用性与当前设置。
func (a *App) APIPlayerStatus() map[string]any {
	vals := map[string]string{
		string(settings.Player):       settings.Get(settings.Player),
		string(settings.PlayerLive):   settings.Get(settings.PlayerLive),
		string(settings.PlayerDecode): settings.Get(settings.PlayerDecode),
		string(settings.PlayerSpeed):  settings.Get(settings.PlayerSpeed),
		string(settings.PlayerScale):  settings.Get(settings.PlayerScale),
	}
	settings.OverlayClientProfile(vals, hostclient.CurrentPlatform())
	cur := strings.TrimSpace(vals[string(settings.Player)])
	if cur == "" {
		cur = "innie#mpv"
	}
	decode := strings.TrimSpace(vals[string(settings.PlayerDecode)])
	if decode == "" {
		decode = "auto"
	}
	out := map[string]any{
		"ok":        true,
		"available": player.Available(),
		"current":   cur,
		"decode":    decode,
		"speed":     vals[string(settings.PlayerSpeed)],
		"scale":     vals[string(settings.PlayerScale)],
	}
	for k, v := range embed.EmbedPlaybackSnapshot() {
		out[k] = v
	}
	return out
}

// APIPlayerEmbed 页内嵌入播放（Flutter 内置 media_kit/FVP 不经此路径）。
// playerVal: innie#mpv；空则用当前设置。
func (a *App) APIPlayerEmbed(playURL, playerVal, histKey string) error {
	playURL = strings.TrimSpace(playURL)
	if playURL == "" {
		return fmt.Errorf("empty url")
	}
	playerVal = strings.TrimSpace(playerVal)
	if playerVal == "" {
		playerVal = settings.Get(settings.Player)
	}
	if playerVal == "" {
		playerVal = "innie#mpv"
	}
	parts := strings.SplitN(playerVal, "#", 2)
	mode := parts[0]
	name := "mpv"
	if len(parts) > 1 && parts[1] != "" {
		name = strings.ToLower(parts[1])
	}
	if mode != "innie" || name != "mpv" {
		return fmt.Errorf("embed 仅支持 innie#mpv")
	}
	settings.Set(settings.Player, playerVal)
	_ = settings.Save()
	return player.Play(playURL, histKey)
}

// APIPlayerControl 控制当前页内嵌入引擎。
// cmd: toggle|play|pause|stop|seek|volume|speed|decode
func (a *App) APIPlayerControl(cmd string, value float64, mode string) error {
	cmd = strings.ToLower(strings.TrimSpace(cmd))
	eng := embed.Active()
	if eng == nil {
		return fmt.Errorf("页内播放器未启动")
	}
	switch cmd {
	case "toggle", "playpause":
		eng.TogglePause()
	case "play":
		if !eng.IsPlaying() {
			eng.TogglePause()
		}
	case "pause":
		if eng.IsPlaying() {
			eng.TogglePause()
		}
	case "stop":
		eng.Stop()
	case "seek":
		eng.SeekMs(int64(value))
	case "volume":
		eng.SetVolume(int(value))
		settings.Set(settings.PlayerVolume, fmt.Sprintf("%d", int(value)))
		_ = settings.Save()
	case "speed":
		if enh, ok := eng.(embed.Enhanced); ok {
			if !enh.SetSpeed(value) {
				return fmt.Errorf("当前内核不支持倍速")
			}
			settings.Set(settings.PlayerSpeed, fmt.Sprintf("%g", value))
			_ = settings.Save()
		} else {
			return fmt.Errorf("当前内核不支持倍速")
		}
	case "decode":
		m := strings.TrimSpace(mode)
		if m == "" {
			m = "auto"
		}
		if enh, ok := eng.(embed.Enhanced); ok {
			enh.SetDecodeMode(m)
			enh.Reload(true)
			settings.Set(settings.PlayerDecode, m)
			_ = settings.Save()
		}
	default:
		return fmt.Errorf("unknown cmd: %s", cmd)
	}
	return nil
}

// APIPlayerExternal 用外部播放器打开 URL；playerVal 如 outie#vlc / outie#mpv / outie#iina。
func (a *App) APIPlayerExternal(playURL, playerVal string) error {
	playURL = strings.TrimSpace(playURL)
	if playURL == "" {
		return fmt.Errorf("empty url")
	}
	playerVal = strings.TrimSpace(playerVal)
	if playerVal == "" {
		playerVal = settings.Get(settings.Player)
	}
	if playerVal == "" {
		playerVal = "outie#mpv"
	}
	parts := strings.SplitN(playerVal, "#", 2)
	mode := parts[0]
	name := "mpv"
	if len(parts) > 1 && parts[1] != "" {
		name = strings.ToLower(parts[1])
	}
	if mode == "innie" {
		return fmt.Errorf("内置播放器请在页内播放")
	}
	settings.Set(settings.Player, playerVal)
	_ = settings.Save()
	return player.ExternalPlay(playURL, name)
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
