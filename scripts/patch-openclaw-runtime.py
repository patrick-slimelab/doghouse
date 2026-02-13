#!/usr/bin/env python3
import glob
import re
from pathlib import Path

main_files = glob.glob('/opt/openclaw/dist/loader-*.js') + glob.glob('/opt/openclaw/dist/reply-*.js') + ['/opt/openclaw/dist/extensionAPI.js']
sandbox_files = glob.glob('/opt/openclaw/dist/sandbox-*.js')

changed = False

def patch_text(path: str, fn):
    global changed
    p = Path(path)
    if not p.exists():
        return
    s = p.read_text(encoding='utf-8')
    n = fn(s)
    if n != s:
        p.write_text(n, encoding='utf-8')
        print(f'[doghouse] patched {path}')
        changed = True

warn = 'if (params.cfg.commands?.bash !== true) return { text: "⚠️ bash is disabled. Set commands.bash=true to enable. Docs: https://docs.openclaw.ai/tools/slash-commands#config" };'

new_require_fn = '''function resolveChannelGroupRequireMention(params) {
\tconst { requireMentionOverride, overrideOrder = "after-config" } = params;
\tconst { groupConfig, defaultConfig } = resolveChannelGroupPolicy(params);
\tconst configMention = typeof groupConfig?.requireMention === "boolean" ? groupConfig.requireMention : typeof defaultConfig?.requireMention === "boolean" ? defaultConfig.requireMention : void 0;
\tif (overrideOrder === "before-config" && typeof requireMentionOverride === "boolean") return requireMentionOverride;
\tconst groupChatCfg = params.cfg?.messages?.groupChat ?? {};
\tconst normalizeMode = (value) => {
\t\tif (typeof value !== "string") return;
\t\tconst v = value.trim().toLowerCase();
\t\tif (!v) return;
\t\tif (v === "hard" || v === "hard-mention") return "hard";
\t\tif (v === "soft" || v === "soft-mention") return "soft";
\t\tif (v === "none" || v === "no" || v === "off" || v === "never" || v === "no-mention") return "none";
\t};
\tconst modeOverrides = groupChatCfg.mentionModeOverrides ?? groupChatCfg.mention_mode_overrides;
\tconst defaultMode = normalizeMode(groupChatCfg.mentionModeDefault ?? groupChatCfg.mention_mode_default);
\tlet effectiveMode;
\tif (modeOverrides && typeof modeOverrides === "object") {
\t\tconst gid = params.groupId?.trim();
\t\tconst candidates = [];
\t\tif (params.channel && gid) candidates.push(`${params.channel}:${gid}`);
\t\tif (gid) candidates.push(gid);
\t\tif (params.channel) candidates.push(`${params.channel}:*`);
\t\tcandidates.push("*");
\t\tfor (const key of candidates) {
\t\t\tif (!key) continue;
\t\t\tconst mode = normalizeMode(modeOverrides[key]);
\t\t\tif (mode) { effectiveMode = mode; break; }
\t\t}
\t}
\teffectiveMode = effectiveMode ?? defaultMode;
\tif (effectiveMode === "hard") return true;
\tif (effectiveMode === "none") return false;
\tif (effectiveMode === "soft") return typeof configMention === "boolean" ? configMention : true;
\tif (typeof configMention === "boolean") return configMention;
\tif (overrideOrder !== "before-config" && typeof requireMentionOverride === "boolean") return requireMentionOverride;
\treturn true;
}'''

new_resolve_patterns = '''function resolveMentionPatterns(cfg, agentId) {
\tif (!cfg) return [];
\tconst agentConfig = agentId ? resolveAgentConfig(cfg, agentId) : void 0;
\tconst agentGroupChat = agentConfig?.groupChat;
\tlet patterns = [];
\tif (agentGroupChat && Object.hasOwn(agentGroupChat, "mentionPatterns")) patterns = agentGroupChat.mentionPatterns ?? [];
\telse {
\t\tconst globalGroupChat = cfg.messages?.groupChat;
\t\tif (globalGroupChat && Object.hasOwn(globalGroupChat, "mentionPatterns")) patterns = globalGroupChat.mentionPatterns ?? [];
\t\telse {
\t\t\tconst derived = deriveMentionPatterns(agentConfig?.identity);
\t\t\tpatterns = derived.length > 0 ? derived : [];
\t\t}
\t}
\tconst groupCfg = cfg.messages?.groupChat;
\tconst singleRegex = groupCfg?.mention_regex ?? groupCfg?.mentionRegex;
\tif (typeof singleRegex === "string" && singleRegex.trim()) patterns = [...patterns, singleRegex.trim()];
\treturn patterns;
}'''

for f in main_files:
    patch_text(f, lambda s: s
        .replace('const bashBangRequested = command.commandBodyNormalized.startsWith("!");', 'const bashBangRequested = false;')
        .replace(warn, 'if (params.cfg.commands?.bash !== true) return null;')
    )

for f in main_files:
    patch_text(f, lambda s: re.sub(r'function resolveMentionPatterns\(cfg, agentId\) \{[\s\S]*?\n\}', new_resolve_patterns, s, count=1))

for f in sandbox_files:
    patch_text(f, lambda s: re.sub(r'function resolveChannelGroupRequireMention\(params\) \{[\s\S]*?\n\}', new_require_fn, s, count=1))

if not changed:
    print('[doghouse] runtime patch: no changes needed')
