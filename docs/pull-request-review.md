# Review Pull Request / Merge Request

整个方案分四期。**P1 —— 只读的 review 面板 —— 已完成**；这份文件记录它交付了什么、
数据实际存在哪里、以及 P2–P4 还欠着什么。

放在代码旁边而不是开一个 issue，是因为下面这些决定属于「半年后会被人不声不响地推翻重来」
的那一类。

---

## P1 —— 已交付的部分

点击侧边栏 Pull Requests / Merge Requests 里的一行，会在工作区打开 review 面板，
盖住 graph 和右边的 commit 面板（详见下面「代码依赖的不变量」）。面板有两个页签：

- **Overview** —— 标题、状态 pill、`base ← head`、review decision、CI 汇总、
  冲突标记、总 ±、描述正文，以及 forge 的 timeline。
- **Files (N)** —— 请求改动的每个文件，带各自的 ± 行数和「已读」勾选，右边是该文件的
  diff。

面板不向 forge 写任何东西。`Checkout` 是唯一会动本地仓库的按钮，并且在 HEAD 已经
是该请求的源分支时禁用。

### 唯一一个不该被重开的决定：diff 走本地 git

文件列表和每个文件的 diff 都来自 `git`，不来自 forge 的 API：先 fetch 请求自己的
head ref，再从 merge base 做 diff。

```
git fetch --force <remote> +refs/pull/<n>/head:refs/thegit/pr/<n>          # GitHub
git fetch --force <remote> +refs/merge-requests/<n>/head:refs/thegit/mr/<n> # GitLab
git diff --numstat --find-renames -z <base>...<head>
git diff --name-status --find-renames -z <base>...<head>
git diff -U3 --find-renames <base>...<head> -- <path> [<newpath>]
```

理由：没有限流、不分页、大请求不会被截断、fetch 过一次之后离线可看，而且渲染走的是
app 里其他 diff 用的同一套 `DiffParser` / `DiffLineRow` —— 行号、hunk、二进制识别
全部白拿。

`refs/pull/N/head` 和 `refs/merge-requests/N/head` 无论分支在哪个仓库都存在于远端，
所以 fork 发来的请求和仓库内的请求走同一条路。

**三个点，不是两个**：`base...head` 从 merge base 开始 diff，因此期间落到 base 上的
提交不会被算成这个请求的改动 —— 和 AI 生成 PR 描述时用的是同一个不对称写法。

**refs 的命名空间是刻意的。** `refs/thegit/pr|mr/<n>` 对 graph 不可见 —— graph 走的是
`--branches --remotes --tags HEAD`，所以 fetch 下来的请求既不加行也不画 ref 徽章。
已用真实 fetch 验证过。热力图是唯一一处要单独排除的：`GitClient.activity` 走 `--all`，
所以它显式加了 `--exclude=refs/thegit/*` —— 别人的请求不该算进这个仓库的活跃度，而且
因为 ref 不会被清理，算进去就是永久的。任何以后新增的 `--all` 遍历都要做同样的事。

### 数据存在哪、活多久

| 数据 | 位置 | 寿命 |
|---|---|---|
| 请求列表（号、标题、分支、作者、draft） | `RepoState.pullRequests`，由 `RepoCache` 持久化 | 跨重启，超过 `prsFreshFor` 重取 |
| 请求页面（状态、decision、CI、冲突、正文） | `RepoState.prDetail`，内存 | 面板开在它上面期间 |
| timeline | `RepoState.prThread`，内存 | 同上 |
| fetch 下来的 head ref | `refs/thegit/pr|mr/<n>`，磁盘 | 永久，除非手动清理 |
| 文件列表 + 各文件 ± | `RepoState.prFiles`，内存 | 面板开着期间 |
| 当前文件的 diff 行 | `RepoState.prDiffLines`，内存 | 直到切换到别的文件 |
| 「已读」勾选 | `RepoState.viewedByRequest`，内存 | **仅本次会话** —— 退出即失，也从不发给 forge |
| `base...head` 区间 | `RepoState.prRange`，内存 | 面板开着期间 |

也就是说：重启之后再打开同一个请求很快（ref 已经在本地），但页面、timeline 和勾选都是
空的，要重新取。

### 代码依赖的不变量

- **同一时刻只有一个阅读面板。** 打开 review 会清掉 diff、file history 和 issue 面板；
  它们每一个也都会反过来清掉 `prToView`。两个叠在一起不等于两个都开着 —— 下面那个是
  够不到的。
- **阅读面板是画在两栏之上，不是把两栏换掉。** review 会盖住 graph **和** commit
  面板（review 跟暂存没有任何关系），但两栏仍留在视图树里。把它们摘掉的代价是：graph
  的滚动位置归零、每次关闭都要重建子树、commit 面板的宽度退回到 app 启动时的值。完整
  推理写在 `RepoView.workArea` 上 —— 想把这里「简化」成 `if/else` 之前先读那段。
- **信号缺失不等于信号良好。** `mergeable: "UNKNOWN"`、空的 `reviewDecision`、空的
  `statusCheckRollup`、GitLab 里 `canceled` 的流水线 —— 全部变成 `nil`，而 `nil` 不画
  任何 chip。header 里任何东西都不得从「没有」推出「绿灯」。
- **每个 task 都按 `prToView?.number` 把门。** 请求可能在 fetch 途中被切换，别人的页面
  不是这一个的。
- **review 永不移动 HEAD，也不要求工作区干净。** diff 是从 fetch 下来的 ref 里读的。

### 代码在哪

| 关注点 | 位置 |
|---|---|
| `PullRequestDetail`、`CheckRollup`、`ReviewDecision`、`ForgeItemKind` | `Core/ForgeClient.swift` |
| `gh pr view` / `glab mr view` 的解析 | `ForgeParsers.pullRequestDetail` |
| issue 与请求共用的 timeline | `ForgeClient.thread(number:kind:forge:)` |
| `ReviewFile` | `Core/Models.swift` |
| `-z` numstat + name-status 解析 | `GitParsers.reviewFiles` |
| fetch、区间、单文件 diff | `GitClient.fetchReviewRefs` / `reviewFiles` / `reviewFileDiff` |
| 面板状态与动作 | `RepoState` 的 "Review a pull/merge request" 一节 |
| 面板本身 | `UI/PullRequestDetailView.swift` |
| timeline 渲染（与 issue 面板共用） | `UI/ForgeTimeline.swift` |
| 测试 | `ForgeParsersTests`、`ReviewDiffTests`、`MenuActionsTests` |

### P1 留下的已知问题

都不大，也都是有意为之，但每一条都是真的洞，不是毛刺：

1. **timeline 跳过了 PR 专属事件。** `ForgeParsers.githubTimeline` 只渲染它认识的类型；
   `reviewed`、`line-commented`、`committed`、`head_ref_force_pushed`、
   `ready_for_review`、`review_requested` 全部被跳过。也就是说**评审人的结论正文和所有
   行内评论，目前在 Overview 页里是看不见的**。这是 P1 最大的洞，也是 P2 应该最先补的。
2. **「已读」勾选不跨重启**，也不与 forge 自己的已读状态双向同步（GitHub 的
   `markFileAsViewed`、GitLab 的 per-file review 状态）。
3. **review ref 只增不减。** 没有任何东西清理 `refs/thegit/**`，review 过很多请求的仓库
   会把它们全留着。
4. **一次 review fetch 期间，这个仓库的其它 git 命令都在排队。** `GitClient` 是 actor，
   所有命令串行。fetch 现在可取消（关掉面板、切到别的请求都会真的杀掉子进程）并且有
   120s 上限，所以卡死是有限的 —— 但在这段时间里刷新、暂存、提交仍然要等，而且工具栏
   的 busy 指示不会亮。真正的解法是给 review 一个自己的 `GitClient`：它只读 fetch 下来
   的 ref，本来就不需要和工作区命令共用那把锁。
5. **GitLab 没有 review decision。** 审批是独立资源（`/merge_requests/:iid/approvals`），
   目前没取 —— 所以 GitLab 上 header 根本不显示 decision chip。
6. **thread 有上限**：5 页 × 100 条，到顶会明说。
7. **窗口重新获得焦点时不刷新。** 面板只在按下自己的刷新按钮时重取，与 app 其他部分的
   行为不一致。
8. **Files 页不支持键盘切换文件。**

---

## P2 —— 能够表态

P2 跨过的那条线是：它会向 forge 写。下面每一件事都是别人看得见的副作用，这正是它们不在
P1 里的原因。

### 表态

```
gh pr review <n> --approve | --request-changes | --comment --body <text>
glab mr approve <n>                    # 审批
glab mr note <n> --message <text>      # 普通评论
```

- GitLab 把 GitHub 合在一起的两件事拆开了：审批和评论是两条命令，而且审批会因为权限
  失败（`403`），评论不会。两者都走 `ForgeFailure.describe`，让错误话说清是哪一种。
- 审批在用户认知里是不可逆的：`gh pr review` 没有撤销，GitLab 则有
  （`glab mr revoke`，别名 `unapprove`）。两边都要先确认再发。

### 行内评论

```
gh api repos/{owner}/{repo}/pulls/<n>/comments -f path=… -F line=… -f commit_id=… -f body=…
glab api projects/:id/merge_requests/<n>/discussions -f position[new_path]=… …
```

风险在于「行的身份」：评论锚定在 `commit_id` + path + 行号上，面板 fetch 之后的一次
force-push 就会让它失效。每条草稿都必须绑定计算 diff 时的那个 head sha，当请求的 head
变化后拒绝提交，并提示「分支已变动，请重新拉取」。

GitLab 的 `position` 对象需要 `base_sha`、`head_sha`、`start_sha` 三个都给全，而且必须
来自 MR 自己的 diff refs，不能用我们本地算出来的区间。

### 合并

```
gh pr merge <n> --squash | --merge | --rebase [--delete-branch]
glab mr merge <n> [--squash] [--remove-source-branch]
```

不可逆，且所有人可见。需要一个明确写出合并策略、以及是否删除分支的确认；当
`hasConflicts == true` 或检查未通过时应当直接拒绝（可以提供覆盖选项，但不能默默放行）。

### P2 还包括

- **补上 timeline 的洞** —— 解析 `reviewed` 和 `line-commented` 事件，让评审结论正文和
  行内评论成为对话的一部分，并把行内评论显示在它们所属的 diff 行上。
- **取 GitLab 的审批**，让 decision chip 在那边也能工作。
- **「已读」勾选存进 `RepoCache`**（仅本地 —— 同步到 forge 属于写操作，跟 P2 其余的写
  一起做）。
- **清理 `refs/thegit/**`** —— 或者在 cleanup 时做，或者在请求离开列表时做。
- **刷新请求的 head**，并在它于打开的 review 之下发生变化时给出提示。

---

## P3 —— AI 辅助 review

复用 commit message 和 PR 描述生成器已经在用的那一套：`AIClient.stream`、`AISettings`，
外加一个与 `PullRequestGenerator` 并列的 prompt 模块。

- 输入：请求的 diff（经过 `CommitMessageGenerator.summarize` 的预算逻辑，它已经能处理
  大 diff）加上描述正文。
- 输出：结构化的 findings —— `file`、`line`、严重度、意见。
- findings 落成**草稿评论，由用户逐条接受、编辑或丢弃**。永远不自动发布。这条线决定了
  这个功能到底能不能被信任。
- 草稿存进 `RepoCache`，并绑定 head sha（见上面行的身份那段）。

## P4 —— 没有 forge 也能 review

同一个面板、同一套 AI 流程，作用在任意两个 ref 上（`feature` vs `main`），只是没有表态
按钮。不装 `gh`/`glab` 也能用，自建的、根本没有 forge 的 git 也能用。地基其实大半已经
在了：`GitClient.reviewFiles` / `reviewFileDiff` 接受的是一个区间而不是请求号 —— 只有
fetch 那一步和面板的 header 假设了 forge 的存在。
