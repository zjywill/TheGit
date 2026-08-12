# 签名与公证

这份文件记录 2026-08-12 那次排查：v0.10.7 是怎么在「签名脚本一路绿灯」的情况下
发出去一个没有公证票的包的，以及为此改了什么。

写下来是因为这里面每一条都属于「看起来已经验过了，其实没验」那一类 —— 后面的人
（包括半年后的自己）会理所当然地认为 `codesign --verify` 通过就等于用户那边没问题，
然后重新踩一遍。

---

## 一个包要过 Gatekeeper，需要三样东西

1. **Developer ID 签名**，带 hardened runtime（`--options runtime`）和安全时间戳。
2. **Apple 的公证**：把包传上去，Apple 扫完给一个 verdict。
3. **贴在包上的票**（`stapler staple`）。

第三步最容易漏，因为漏掉它**在联网的机器上看不出来**。Apple 服务器上有票、本地文件
上没有，一台联网的 Mac 会去线上查，一路放行；断网的那台就打不开了。

而且票要**两张**：镜像一张，镜像里的 .app 一张。DMG 上的票只覆盖 DMG —— 用户把 app
拖进 /Applications、把镜像扔掉之后，Gatekeeper 读的是 app 自己身上那张。

### 公证不会改你的文件，也不用从 Apple 下载回来

这是最容易误解的一点。上传上去的是一份**副本**，Apple 扫完就丢；它只回一个 verdict，
并按这个包的 cdhash 在自己服务器上记一张票。`stapler staple` 才是去把那张票拉下来、
写进**你本地那个文件**。发出去的自始至终是本地这份，没有任何东西需要从 Apple 取回。

票很小，对一个 .app 来说就是多出来的一个 `Contents/CodeResources`（约 1.6 KB）：

```
Contents/CodeResources     ← 票，stapler 写的
Contents/_CodeSignature/   ← 签名，codesign 写的，两回事
```

所以「Accepted 了」和「包能用了」是两件事，中间隔着 `stapler staple` 这一步 ——
v0.10.7 就是卡在这里：上传成功、verdict Accepted、第三步没执行。

---

## v0.10.7 出了什么事

发布出去的 DMG（和 `dist/` 里那份字节一致）：

| 检查 | DMG | 镜像里的 .app |
|---|---|---|
| `codesign --verify --strict` | 过 | 过 |
| `stapler validate` | **没票** | **没票** |
| `spctl --assess` | accepted | accepted |
| `syspolicy_check distribution` | — | **失败** |

`notarytool history` 说明了全过程：那个 DMG 被 Apple **Accepted 过三次**
（06:06Z、06:37Z、08:42Z），票一直在 Apple 服务器上，本地文件一次都没贴上。

### 为什么脚本没拦住

三个独立的漏洞，每一个单独看都像是没问题的代码。

**一、`stapler staple` 的失败被吞了。**

`notarise()` 里原本是这样：

```bash
if grep -q "status: Accepted" "$log"; then
    xcrun stapler staple "$2"
    return 0
fi
```

调用点是 `if ! notarise "$ZIP" "$APP"; then`。bash 在 `if` 的条件里会**整段挂起
errexit**，所以 staple 失败不会中止函数，直接落到下一行 `return 0` 报成功。改成
`xcrun stapler staple "$2" || return 1`。

**二、验证的是签名，不是分发结果。**

原来全程只有 `codesign --verify --strict`。它证明的是「签名内部自洽」——
ad-hoc 包过，Apple 从没见过的 Developer ID 包也过。它和有没有公证票完全无关。

`spctl` 看起来更严，其实更不能信：**它会联网问 Apple**。上面那张表里
`spctl --assess` 对两个没票的文件都回了 accepted，因为票确实存在，只是不在文件上。
只用 spctl 把关，等于永远发现不了漏贴。

真正读「包里那张票」的只有两个：

- `xcrun stapler validate`
- `syspolicy_check distribution`（macOS 14+，失败返回 70）

现在 `verify_distribution()` 四个一起跑，app 和 DMG 各验一次，release.sh 打 tag
之前再独立验一次（不采信 bundle.sh 的说法，因为 tag 是收不回来的那一步）。

**三、补票脚本只补了一半。**

`notarise-release.sh` 原来只给 DMG 补票。镜像是只读的，里面的 app 永远补不上，
等于结构上做不到「两张票」。现在的流程是：从 Release 上下载真正发出去的那个 DMG
→ 取出 app → 给 app 拿票、贴上 → 围着贴好票的 app 重做镜像 → 签 → 给镜像拿票、
贴上 → 两头都验 → 换资源 → 改 notes。二进制自始至终是发出去的那个。

---

## 公证的两个非直觉行为

**容器公证会给里面的代码发票。** 公证一个 DMG，Apple 连同镜像里的东西一起公证，
给里面 .app 的 cdhash 也签发票。所以 v0.10.7 那个 app 的票**早就存在**，只是从来
没人去取 —— `stapler staple` 0.4 秒就贴上了，一次新提交都不需要。

因此 `notarise()` 现在**排队之前先试一次 `stapler staple`**：命中就直接完事，
没命中也只是 0.4 秒的失败。

**票按 cdhash 存，而且 Apple 一直留着。** 所以：

- 放弃等待不损失任何东西，票落地之后重跑一次一秒贴上；
- 反过来，任何会改变 cdhash 的重建都会让之前的票失效。

第二条有个具体的坑：`hdiutil` 做出来的镜像**不是可复现的**。同样的 app、同样的
参数连做两次，CDHash 不同。所以补票脚本如果每次重跑都重做镜像，就是每次给 Apple
一个新哈希，永远收敛不了 —— 它现在会复用上一轮做好的镜像。

---

## 这个 team 的公证有多慢

2026-08-12 是这个 Developer ID 第一次用公证服务。当天九次提交：

```
02:58Z  app   In Progress   （八小时后仍未回）
04:01Z  probe In Progress
05:23Z  probe In Progress
05:23Z  app   In Progress
06:06Z  dmg   Accepted
06:37Z  dmg   Accepted
08:42Z  dmg   Accepted       （约 11:20Z 才翻，等了两个半小时）
10:40Z  dmg   In Progress
11:11Z  app   In Progress
```

**这不是 Apple 当时慢，也不是包有问题**，两者都另有对照可以排除：账号有问题会在提交
阶段就报认证错，内容有问题回的是 `Invalid` 而不是 `In Progress`。这就是一个刚开始
用公证服务、没有历史的 Developer ID 的样子，跑一段时间会好转。

### 由此得出的两个结论，都写进默认值了

**重试循环是帮倒忙的。** verdict 要几小时才回来，而 `NOTARY_TIMEOUT` 原本是 20 分钟
—— 脚本永远等不到结果，白烧三轮然后放弃，而那三次提交后来全都 Accepted 了，只是没人
在那儿接。06:06Z 和 06:37Z 那两条正好隔 31 分钟，就是重试循环打出来的。

重新提交**不能插队**，只是往一个慢队列里再塞一个。默认值因此改成
`NOTARY_TIMEOUT=2h`、`NOTARY_RETRIES=1`。**不要为了「快点过去」把它改回来。**

**Ctrl-C 是受支持的用法。** 提交不会丢，票会留着，重跑时 `notarise()` 的快路径一秒
贴上。脚本在等待时会把这句话打出来。

唯一的例外是 `release.sh`：它里面的 `bundle.sh` 会重新 `swift build`，重跑就是新的
二进制、新的 cdhash，票对不上。所以在这个账号变快之前，发版按下面这个形状走 ——
**没有任何一步需要你守在终端前面**。

### 实际的发版流程

**第一步，发出去**（几分钟，不碰公证）：

```bash
NOTARIZE=0 ALLOW_UNNOTARISED=1 scripts/release.sh X.Y.Z
```

跑完版本就上线了，notes 里自动带着 Gatekeeper 绕路说明。

**第二步，同一条命令反复跑**，想起来就跑一次：

```bash
scripts/notarise-release.sh X.Y.Z
```

它**不等 Apple**。每次尽可能往前推一步，把 submission id 记在
`dist/.notary-X.Y.Z/`（gitignored），然后告诉你回头再来。典型是三次：

| 第几次 | 做了什么 | 耗时 |
|---|---|---|
| 1 | 提交 app | 几十秒 |
| 2 | 贴 app 的票、做镜像、提交镜像 | 一分钟 |
| 3 | 贴镜像的票、验、换资源、改 notes | 一分钟 |

中间隔多久无所谓。已经做完的那一段每次都是秒过（先试 `stapler staple`），**已经在
排队的不会重复提交**（读状态文件里的 id 去查，不是盲目再交一次）—— 后者很重要，
重新提交只会往慢队列里再塞一个。

如果跑的时候两张票都已经到位，它就一次把整件事做完。

### 队列清不掉

`notarytool` 只有 `store-credentials` / `submit` / `info` / `wait` / `history` /
`log`，没有 cancel 也没有 delete。卡住的提交没有办法撤销，也不需要撤销：它们不占额度、
不阻塞新提交，时间到了自己会翻。

---

## 一个和公证无关、但同样静默的坑

`set -o pipefail` 加上会提前退出的管道消费者，等于给自己埋雷：

```bash
codesign -dv --verbose=4 "$DMG" 2>&1 | grep -q "Authority=Developer ID Application"
```

`grep -q` 找到第一处匹配就退出，`codesign` 还有十几行没写完，收到 SIGPIPE 死掉
（141），`pipefail` 把这个 141 当成整条管道的状态。结果是这个检查对**任何**正确签名
的 DMG 都报「没签名」，稳定复现。

同样的形状还有 `| head -1`：head 拿到一行就退出，上游照样被打死。

- 要判断输出里有没有某个字符串：先 `x="$(cmd 2>&1 || true)"` 捕获，再用 `case` 匹配。
- 要取第一行：用 `sed -n 1p`，它读到 EOF 才结束，没有人可杀。

---

## Homebrew 为什么从 formula 换成 cask

formula 是从源码本地编译的。Homebrew 的构建环境**读不到登录钥匙串**，所以
`bundle.sh` 在那里找不到 Developer ID 证书，落到 ad-hoc 分支。

ad-hoc 包每次重建都换一个身份，而 macOS 的钥匙串条目是按存入时的签名身份认的 ——
所以每次 `brew upgrade` 都会重新问一遍 AI API key（`AICredentials.swift` 顶上那段
注释里「bundled .app 不会再弹」只对 DMG 成立）。

cask 直接装已公证的 DMG：签名身份稳定，钥匙串只弹一次，也不需要用户自己往
`/Applications` 拷。不要为了「避开 Gatekeeper」把 formula 换回来 —— cask 装的包
是公证过的，没有 Gatekeeper 可避。

---

## 手动核对一个包的时候

```bash
xcrun stapler validate <包>                  # 唯一直接读本地票的快检查
syspolicy_check distribution <app>           # 失败返回 70，会说清楚缺什么
spctl -a -vvv -t execute <app>               # 会联网，单独用它不能作数
spctl -a -vvv -t open --context context:primary-signature <dmg>
xcrun notarytool history --keychain-profile thegit
```

镜像里的 app 要挂起来单独看，别只看镜像：

```bash
hdiutil attach -nobrowse -readonly -mountpoint /tmp/m dist/TheGit-X.Y.Z.dmg
syspolicy_check distribution /tmp/m/TheGit.app
hdiutil detach /tmp/m
```

脚本里这一整套是 `scripts/release-lib.sh` 的 `verify_distribution()` 和
`verify_dmg_contents()`。
