# Skill Description 精简方法论

> 每一个启用的 skill 的 `description` 字段都会出现在**每次会话**的 system-reminder 里，全文加载、永久燃烧 token。这是 Pattern 1 的子模式：**skill manifest bloat**。

## 为什么这个收益被低估

- 一个项目可能有 40 个启用的 skill
- 平均每个 description 200 字符 = 8000 字符 / 会话
- 1000 次会话 = 8M 字符 ≈ 2M tokens 的不可回收浪费
- 大多数 description 是**作者写给自己看的**：详细列功能、列触发短语、列输出格式——但 trigger matching 是 fuzzy 的，**穷举 10 个同义词不会比 3 个匹配得更准**

实测案例：43 个启用 skill，原始 description 总长 ~8500 字符。优化后 ~2800 字符，省 67%（约每会话 -2000 tokens）。

## 审计步骤

### 1. 枚举 + 排序

```python
import os, re, yaml
for d in sorted(os.listdir('/Users/USER/.claude/skills')):
    real = os.path.realpath(os.path.join('/Users/USER/.claude/skills', d))
    f = os.path.join(real, 'SKILL.md')
    if not os.path.isfile(f): continue
    txt = open(f).read()
    m = re.match(r'^---\n(.*?)\n---', txt, re.S)
    if not m: continue
    try:
        fm = yaml.safe_load(m.group(1))
        desc = fm.get('description', '')
        print(f"{len(desc):4d}  {d}")
    except Exception as e:
        print(f"   ?  {d}  YAML ERROR: {e}")
```

按字符数倒序输出，前 10–20 个就是 80% 的浪费来源。

### 2. 分级处理

| 长度 | 行动 | 典型问题 |
|------|------|---------|
| **>400c** | 必改 | 长篇说明 + 完整功能清单 + 10+ 触发短语穷举 + 输出路径 |
| **200–400c** | 改 | 触发短语过多重复、bilingual 复述、实现细节 |
| **150–200c** | 视情况 | 只在有明显冗余（如「触发：」段塞了 6 个同义词）时改 |
| **<150c** | 不动 | 通常已经够紧 |

### 3. 压缩原则

**保留**：
- 一句话功能描述（"做什么"）
- 2–3 个最具代表性的触发短语
- 重要的"不适用"边界（例：「不用于 Mermaid」）

**删除**：
- 详尽的功能列表（"animations, title cards, overlays, captions, voiceovers..." → 用一个上位词）
- bilingual 重复（中英两段重复同一意思）
- 实现细节（输出路径、文件格式、依赖技术栈枚举）
- 触发短语穷举（"用 X 视角」「X 会怎么看」「X 模式」「X perspective」「按 X 的方式拆这个" → 留 1–2 个）
- 元描述（"This is a full pipeline skill"、"Use this skill whenever..."）

**模板**：
```
[做什么的一句话]——[关键能力或子模块]。触发：[短语1]、[短语2]、[短语3]。
```

## YAML 写作陷阱（必须避开）

### 陷阱 1：前置双引号截断 description

```yaml
# ❌ YAML 把 "电子杂志" 解析为完整字符串，剩下文字成无效内容
description: "电子杂志 × 电子墨水"风格的横向翻页 PPT。触发：杂志风 PPT...

# ✅ 改为无前置引号（中文标题用书名号或破折号）
description: 电子杂志 × 电子墨水风格的横向翻页 PPT。触发：杂志风 PPT...
```

### 陷阱 2：mid-line 冒号触发 mapping 解析错误

```yaml
# ❌ "Triggers:" 被 YAML 当成新的 key，报 "mapping values are not allowed here"
description: Use when X. Triggers: weekly review, executive audience, ...

# ✅ 用中文「触发：」或换成短横/箭头分隔
description: Use when X. 触发：weekly review、executive audience、...
description: Use when X — triggers include weekly review, executive audience, ...
```

实战中**任何**英文「Triggers: 」「Examples: 」「Note: 」都会破 YAML。换成中文标点是最简单解。

### 陷阱 3：block scalar 的隐性长度

```yaml
# 用 | 块标量看似优雅，但每个换行也算字符
description: |
  长篇说明第一行。
  第二行。
  第三行。
```

实际渲染到 system-reminder 时：换行被保留，每个换行 = 1 字符 + 显著降低密度。**优先单行**，超过 200 字符再考虑块标量。

### 陷阱 4：harness 的解析比 PyYAML 宽容

YAML 严格解析失败的 description，harness 仍可能"正常显示"（用了非严格 parser）。**不要因为表面正常就忽略 PyYAML 报错**——破坏的语义边界迟早出问题（如下一次有人用 yaml.safe_load 验证就 0c）。

## 验证

改完后重跑枚举脚本：
- 所有 description 都能 `yaml.safe_load` 通过
- 字符数 = 你期望的长度（不应大幅偏离）
- 重启 Claude Code 后观察 system-reminder 中是否显示新描述

## 关联清理：user-invocable-skills.json

`~/.claude/user-invocable-skills.json` 是斜杠菜单的白名单。常见问题：

- skill 目录被归档/删除，但白名单条目还在
- 用户调用斜杠菜单时点中失效条目，调用失败

清理脚本：

```python
import json, os
SKILLS_DIR = '/Users/USER/.claude/skills'
F = '/Users/USER/.claude/user-invocable-skills.json'

cfg = json.load(open(F))
old = cfg['userInvokableSkills']
new = [s for s in old if os.path.exists(os.path.join(SKILLS_DIR, s))]
cfg['userInvokableSkills'] = new
json.dump(cfg, open(F, 'w'), ensure_ascii=False, indent=2)
print(f"Removed {len(old) - len(new)} stale entries")
```

## 批量改写脚本（参考实现）

```python
#!/usr/bin/env python3
"""批量替换 SKILL.md description 字段，保留其他 frontmatter。"""
import os, re

NEW_DESCS = {
    'skill-name-1': '新描述 1',
    'skill-name-2': '新描述 2',
    # ...
}

def replace_description(filepath, new_desc):
    content = open(filepath).read()
    m = re.match(r'^(---\n)(.*?)(\n---\n)', content, re.S)
    if not m:
        return False
    head, fm, tail = m.group(1), m.group(2), m.group(3)

    lines = fm.split('\n')
    out, i, replaced = [], 0, False
    while i < len(lines):
        line = lines[i]
        # 块标量起始
        if not replaced and re.match(r'^description:\s*[|>][-+]?\s*$', line):
            out.append(f'description: {new_desc}')
            i += 1
            while i < len(lines) and (lines[i].startswith('  ') or lines[i].strip() == ''):
                if lines[i].strip() == '' and i+1 < len(lines) and re.match(r'^[a-zA-Z_]', lines[i+1]):
                    break
                i += 1
            replaced = True
            continue
        # 单行 description
        elif not replaced and line.startswith('description:'):
            out.append(f'description: {new_desc}')
            replaced = True
            i += 1
            continue
        out.append(line)
        i += 1

    if not replaced: return False
    open(filepath, 'w').write(head + '\n'.join(out) + tail + content[m.end():])
    return True

for skill, new_desc in NEW_DESCS.items():
    skill_md = os.path.join('/Users/USER/.claude/skills', skill, 'SKILL.md')
    real = os.path.realpath(skill_md)  # 处理 symlink
    if os.path.isfile(real):
        replace_description(real, new_desc)
```

## 何时跑这个清理

- 每次新装 5+ skill 后
- 感觉 system-reminder 加载明显变长时
- audit.sh 显示本地 skill 数 ≥ 30 时
- 跑 `analyze.py` 发现 input token / 会话异常高时

## 成本/收益

- 每个 skill 平均压缩 200c → 100c：节省 100 字符 / 会话
- 30 个 skill 全压：3000 字符 / 会话 ≈ 750 tokens
- 假设每天 30 个会话：22500 tokens/天 = 675K tokens/月 = 一笔显著的 input cache miss 节约
- 改一次受益所有未来会话——**最高 ROI 的 token 投资之一**
