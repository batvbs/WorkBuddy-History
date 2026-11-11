# docs/ —— model.csv 的原始数据来源

这里的 JSON 是 `model.csv` 的取值依据，从客户端里取出来留档，
方便日后核对，或在新版本客户端出来之后重新生成 model.csv。

## ⚠️ 先搞清哪份才是「客户端真正在用的」

客户端的「添加自定义模型」用的是**远端配置**，不是安装包里的表：

| | 地址 | 条数 |
|---|---|---|
| 国际版 | `https://download.codebuddy.ai/connectors-config-v2/custom-model/customModelSettings.json` | providers 18 / modelOptions **162** |
| 国内版 | `https://static.workbuddy.cn/connectors-config-v2/custom-model/customModelSettings.json` | providers 16 / modelOptions **160** |

安装包里 `contexts.js` 里的那张表（`lz`，94 条）**只是拉取失败时的兜底**。
一开始我按兜底表统计，得出「100% 覆盖」，是**虚高的**——
换成远端配置后真实覆盖率只有 79.6% / 76.2%，补了一轮才到 96%。

- `preset-models-intl.json` / `preset-models-cn.json`：这两份远端配置的完整留档（含 `data` 原样）。
- **怎么重新拉**：直接 GET 上面两个地址即可，无需登录。

### 两个版本到底差什么

**差的是服务商，不是模型能力。** `providers[].disabledInRegions` 决定该服务商在
`domestic` / `overseas` 哪边可见：

| | 可见服务商 |
|---|---|
| 国际版（18） | deepseek、gemini、glm-coding、glm-open-platform、kimi-coding、kimi-intl、minimax-intl、openrouter、tencent-coding、tencent-token-plan(-lite/-pro/-sg)、tencent-tokenhub(-sg)、together-ai、custom |
| 国内版（16） | deepseek、glm-coding、glm-open-platform、kimi-cn、kimi-coding、minimax-cn、tencent-coding、tencent-token-plan(-hy/-lite/-pro/-sg)、tencent-tokenhub(-sg)、custom |

- 国际版多出：`gemini`（Google 在 `disabledInRegions:["domestic"]`）、`openrouter`、
  `together-ai`、`kimi-intl`、`minimax-intl`
- 国内版多出：`kimi-cn`、`minimax-cn`、`tencent-token-plan-hy`（混元套餐）
- 模型能力本身（`supportsTools/Images/Reasoning`、`maxInputTokens/OutputTokens`）
  两边一致；差异只在**可见的服务商和它们各自挂的模型**上。

## builtin-models.json（1011 条）

**是什么**：安装包里内置的模型清单，每条带 `provider` / `baseUrl` /
`contextWindow` / `maxTokens` / `input`（是否支持图片）/ `reasoning` /
`thinkingLevelMap`（有哪些推理档位）。

**从哪来**：`app.asar` 里的 `/main/common.js` 和 `/renderer/assets/contexts-*.js`。

**注意**：这份清单里**同一个模型会出现多次**，分属不同服务商。比如 `deepseek-flash`
同时挂在 `deepseek`（官方自营）和 `openrouter` / `fireworks`（聚合商）下，
**聚合商那几份的 `contextWindow` 是被改写过的**，不是模型真实上限。
所以 model.csv 只采信「官方自营」那份。

## 两版安装包里的静态数据是一样的

国内版（`D:/APP/WorkBuddyAI`）和国际版（`D:/APP/WorkBuddy`）的
内置清单、预设表**逐条相同**（1011 条 / 23 服务商 / 94 预设模型，0 差异）；
只有构建产物的哈希文件名不同。**真正的差异来自上面那两份远端配置。**

## model.csv 覆盖到什么程度

用客户端**实际生效的远端配置**统计（这才是真实口径）：

| 数据 | 条数 | 命中 | 覆盖率 |
|---|---|---|---|
| 国际版（可见服务商下的模型选项） | 162 | 156 | **96.3%** |
| 国内版（可见服务商下的模型选项） | 160 | 154 | **96.2%** |

未命中的只剩 6 条/版，都是**故意不填**的：

- `auto`（5 处，各套餐的「自动」档）—— 这是**客户端保留的内置模型 id**
  （`auto` / `auto-chat` / `fast-model` / `balanced-model` / `deep-model`）。
  往 models.json 里写一个 `auto` 会和客户端自己的自动档**撞名**，所以不能预填。
- `tc-code-latest` —— 它的 displayName **也叫 "Auto"**，是腾讯 Coding Plan 的自动档，
  同理不填。

（早先用本地兜底表算出的 95.7% / 官方自营 100%，是口径不对造成的虚高，已废弃。）

### 补进来的那些型号

按远端配置补的（之前完全没覆盖）：`hy4` / `hy4-preview`、`mimo-v2.5-pro` /
`mimo-v2.6-pro` / `mimo-v2.6-flash`、`step-5-preview`，以及带 vendor 前缀的
`deepseek/deepseek-flash` / `deepseek/deepseek-v4-flash-vision-exp`。

### 混元系列（内置表里没有，仍然预填了）

内置清单里**一条腾讯/混元的条目都没有**（那是腾讯自营渠道，不在通用清单里），
但混元是**开源**的，用户完全可能自行部署或用第三方托管，所以单独加了：

```
hunyuan-2.0-instruct / hunyuan-2.0-thinking / hunyuan-t1 / hunyuan-turbos / hunyuan-*
hy3 / hy3-preview / hy3*        第三代，192K 上下文
hy4 / hy4-preview / hy4*        第四代，983040 上下文（值取自远端配置）
```

取不到值的列留空（留空 = 不写该字段，客户端跟随自身默认，比编一个数字强）。

### 聚合商前缀去掉之后，和官方表差多少

把 895 条聚合商条目的前缀（`@cf/`、`workers-ai/`、`accounts/<vendor>/models/`、
`<vendor>/` 等）剥掉后：

| | 条数 | 占比 |
|---|---|---|
| 能和官方自营条目对上 | 155 | 17.3% |
| 对不上（聚合商独有） | 740 | 82.7% |

对上的这 155 条里，**取值和官方条目完全一致的只有 59 条，不一致的有 96 条（62%）**：

```
模型                        官方(ctx, max)              聚合商(ctx, max)         聚合商
glm-5.2                     (1000000, 131072)          (262144, 256000)       cloudflare-workers-ai
glm-5.3                     (1000000, 131072)          (1310720, 1310720)     cloudflare-workers-ai
minimax-m3                  (1048576, 512000)          (524288, 250000)       together
deepseek-v4-pro             (1000000, 384000)          (512000, 384000)       together
```

**结论**：聚合商经常改写上下文长度，用它们的值会得到错的数字。这就是
model.csv **只采信官方自营 provider** 的原因。

## model.csv 的列（10 列）

```
id, 支持工具, 支持图片, 支持思考, 推理档位, 默认档位, 上下文长度, 输出长度, 隐藏模型, 图标
```

- **上下文长度** → `maxInputTokens`（输入上限）
- **输出长度** → `maxOutputTokens`（输出上限）

这两列是分开的：早期版本只有「上下文长度」，它只填输入上限，输出上限只能靠接口
返回 —— 网关不报就一直是空。现在补上了「输出长度」，两半都能从表里补。

## 怎么重新生成

数据和它的提取脚本不在这个目录里（脚本是一次性工具）。要重新生成的话：

**第一步是把真正生效的那份配置拉下来**——客户端「添加自定义模型」用的是远端配置，
不是安装包里的表（见上文「先搞清哪份才是客户端真正在用的」）。只从安装包里抠，
覆盖率会停在 79.6% / 76.2% 那档：

1. 两版远端配置都 GET 下来存档（无需登录）：
   - 国际版 `https://download.codebuddy.ai/connectors-config-v2/custom-model/customModelSettings.json`
     → 存成 `preset-models-intl.json`
   - 国内版 `https://static.workbuddy.cn/connectors-config-v2/custom-model/customModelSettings.json`
     → 存成 `preset-models-cn.json`
2. 用 asar 工具解出 `D:/APP/WorkBuddyAI/resources/app.asar` 里的
   `/main/common.js` 和 `/renderer/assets/contexts-*.js`（这里取的是**内置清单**；
   `contexts-*.js` 里那张 94 条的预设表只是拉取失败时的**兜底**，别拿它当预设来源）
3. 从 `contexts-*.js` 里抠 `{"id":"...","name":"...","api":"...","baseUrl":"..."}` 对象 → 内置清单
4. 按上面的口径（只采信官方自营 provider）把**远端配置**和内置清单翻成 model.csv 的行
5. **手工补上数据源里没有的那几类条目**，否则覆盖率到不了文档里写的 96%。
   这些在内置表和远端配置里都没有、或不全，是人工加的，重跑一遍不会自动带上：
   - 混元 `hunyuan-*` / `hy4*`（内置清单里一条腾讯/混元都没有，见上文「混元系列」）
   - 小米 `mimo-*`（`mimo-v2.5-pro` / `mimo-v2.6-pro` / `mimo-v2.6-flash`）
   - 阶跃 `step-*`（`step-5-preview`）
   - 带 vendor 前缀的 id，如 `deepseek/deepseek-flash` /
     `deepseek/deepseek-v4-flash-vision-exp`
