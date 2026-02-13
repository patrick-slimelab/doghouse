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
	const { requireMentionOverride, overrideOrder = "after-config" } = params;
	const { groupConfig, defaultConfig } = resolveChannelGroupPolicy(params);
	const configMention = typeof groupConfig?.requireMention === "boolean" ? groupConfig.requireMention : typeof defaultConfig?.requireMention === "boolean" ? defaultConfig.requireMention : void 0;
	if (overrideOrder === "before-config" && typeof requireMentionOverride === "boolean") return requireMentionOverride;
	const groupChatCfg = params.cfg?.messages?.groupChat ?? {};
	const normalizeMode = (value) => {
		if (typeof value !== "string") return;
		const v = value.trim().toLowerCase();
		if (!v) return;
		if (v === "hard" || v === "hard-mention") return "hard";
		if (v === "soft" || v === "soft-mention") return "soft";
		if (v === "none" || v === "no" || v === "off" || v === "never" || v === "no-mention") return "none";
	};
	let envOverrides = {};
	try {
		if (process?.env?.OPENCLAW_MENTION_MODE_OVERRIDES) envOverrides = JSON.parse(process.env.OPENCLAW_MENTION_MODE_OVERRIDES);
	} catch {}
	const modeOverrides = (envOverrides && typeof envOverrides === "object" ? envOverrides : {}) || groupChatCfg.mentionModeOverrides || groupChatCfg.mention_mode_overrides || {};
	const defaultMode = normalizeMode(process?.env?.OPENCLAW_MENTION_MODE_DEFAULT) ?? normalizeMode(groupChatCfg.mentionModeDefault ?? groupChatCfg.mention_mode_default);
	let effectiveMode;
	if (modeOverrides && typeof modeOverrides === "object") {
		const gid = params.groupId?.trim();
		const candidates = [];
		if (params.channel && gid) candidates.push(`${params.channel}:${gid}`);
		if (gid) candidates.push(gid);
		if (params.channel) candidates.push(`${params.channel}:*`);
		candidates.push("*");
		for (const key of candidates) {
			if (!key) continue;
			const mode = normalizeMode(modeOverrides[key]);
			if (mode) { effectiveMode = mode; break; }
		}
	}
	effectiveMode = effectiveMode ?? defaultMode;
	if (effectiveMode === "hard") return true;
	if (effectiveMode === "none") return false;
	if (effectiveMode === "soft") return typeof configMention === "boolean" ? configMention : true;
	if (typeof configMention === "boolean") return configMention;
	if (overrideOrder !== "before-config" && typeof requireMentionOverride === "boolean") return requireMentionOverride;
	return true;
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


# Matrix extension: hard mode should only honor explicit mentions.
matrix_handler = Path('/opt/openclaw/extensions/matrix/src/matrix/monitor/handler.ts')
if matrix_handler.exists():
    ms = matrix_handler.read_text(encoding='utf-8')
    orig = ms
    old = """      const { wasMentioned, hasExplicitMention } = resolveMentions({
        content,
        userId: selfUserId,
        text: bodyText,
        mentionRegexes,
      });"""
    new = """      const { wasMentioned, hasExplicitMention } = resolveMentions({
        content,
        userId: selfUserId,
        text: bodyText,
        mentionRegexes,
      });
      const mentionMode = (() => {
        const parseMode = (value: unknown): "hard" | "soft" | "none" | undefined => {
          if (typeof value !== "string") return undefined;
          const v = value.trim().toLowerCase();
          if (v === "hard" || v === "hard-mention") return "hard";
          if (v === "soft" || v === "soft-mention") return "soft";
          if (v === "none" || v === "no" || v === "off" || v === "never" || v === "no-mention") return "none";
          return undefined;
        };
        let overrides: Record<string, string> = {};
        try {
          if (process.env.OPENCLAW_MENTION_MODE_OVERRIDES) {
            const parsed = JSON.parse(process.env.OPENCLAW_MENTION_MODE_OVERRIDES);
            if (parsed && typeof parsed === "object") overrides = parsed as Record<string, string>;
          }
        } catch {}
        const defaultMode = parseMode(process.env.OPENCLAW_MENTION_MODE_DEFAULT) ?? "hard";
        const fromOverride = parseMode(overrides[`matrix:${roomId}`] ?? overrides[roomId] ?? overrides["matrix:*"] ?? overrides["*"]);
        return fromOverride ?? defaultMode;
      })();
      const softRegexHit = (() => { try { const rx = process.env.OPENCLAW_MENTION_REGEX; return typeof rx === "string" && rx.trim().length > 0 ? new RegExp(rx, "i").test(bodyText) : false; } catch { return false; } })();
      const effectiveWasMentioned = mentionMode === "hard" ? hasExplicitMention : mentionMode === "soft" ? (hasExplicitMention || softRegexHit) : true;"""
    old2 = """      const shouldRequireMention = isRoom
        ? roomConfig?.autoReply === true
          ? false
          : roomConfig?.autoReply === false
            ? true
            : typeof roomConfig?.requireMention === "boolean"
              ? roomConfig?.requireMention
              : true
        : false;"""
    new2 = """      const shouldRequireMentionBase = isRoom
        ? roomConfig?.autoReply === true
          ? false
          : roomConfig?.autoReply === false
            ? true
            : typeof roomConfig?.requireMention === "boolean"
              ? roomConfig?.requireMention
              : true
        : false;
      const shouldRequireMention = mentionMode === "none" ? false : mentionMode === "hard" || mentionMode === "soft" ? true : shouldRequireMentionBase;"""
    if old in ms:
        ms = ms.replace(old, new, 1)
    if old2 in ms:
        ms = ms.replace(old2, new2, 1)
    ms = ms.replace('        !wasMentioned &&', '        !effectiveWasMentioned &&', 1)
    ms = ms.replace('      if (isRoom && shouldRequireMention && !wasMentioned && !shouldBypassMention) {', '      if (isRoom && shouldRequireMention && !effectiveWasMentioned && !shouldBypassMention) {', 1)
    if ms != orig:
        matrix_handler.write_text(ms, encoding='utf-8')
        print('[doghouse] patched /opt/openclaw/extensions/matrix/src/matrix/monitor/handler.ts')
        changed = True



# Matrix extension: in-room /activation override map (hard|soft|none) + command handling.
if matrix_handler.exists():
    ms = matrix_handler.read_text(encoding='utf-8')
    orig2 = ms
    if 'const matrixActivationOverrides = new Map<string, "hard" | "soft" | "none">();' not in ms:
        ms = ms.replace('import { EventType, RelationType } from "./types.js";\n', 'import { EventType, RelationType } from "./types.js";\n\nconst matrixActivationOverrides = new Map<string, "hard" | "soft" | "none">();\nfunction parseMatrixActivationCommand(text: string): "hard" | "soft" | "none" | null {\n  const m = text.trim().match(/^\\/activation(?:\\s*:\\s*|\\s+)(mention|always|soft|hard|none)\\s*$/i);\n  if (!m) return null;\n  const v = (m[1] || "").toLowerCase();\n  if (v === "mention" || v === "hard") return "hard";\n  if (v === "always" || v === "none") return "none";\n  if (v === "soft") return "soft";\n  return null;\n}\n')
    ms = ms.replace('        const fromOverride = parseMode(overrides[`matrix:${roomId}`] ?? overrides[roomId] ?? overrides["matrix:*"] ?? overrides["*"]);\n        return fromOverride ?? defaultMode;', '        const fromRuntime = matrixActivationOverrides.get(roomId);\n        if (fromRuntime) return fromRuntime;\n        const fromOverride = parseMode(overrides[`matrix:${roomId}`] ?? overrides[roomId] ?? overrides["matrix:*"] ?? overrides["*"]);\n        return fromOverride ?? defaultMode;')
    hook = '      const commandAuthorized = commandGate.commandAuthorized;\n'
    inject = '      const commandAuthorized = commandGate.commandAuthorized;\n      const activationMode = parseMatrixActivationCommand(bodyText);\n      if (isRoom && activationMode && commandAuthorized) {\n        matrixActivationOverrides.set(roomId, activationMode);\n        await sendMessageMatrix({\n          client,\n          roomId,\n          text: `⚙️ Activation set to ${activationMode}.`,\n          markdown: true,\n          eventId: event.event_id,\n          fallbackReplyToMode: replyToMode,\n          threadRootId: undefined,\n        });\n        return;\n      }\n'
    if hook in ms and inject not in ms:
        ms = ms.replace(hook, inject, 1)
    if ms != orig2:
        matrix_handler.write_text(ms, encoding='utf-8')
        print('[doghouse] patched matrix /activation runtime overrides')
        changed = True

