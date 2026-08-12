# The plumbing a release shares: finding the signing identity, assembling the
# DMG, getting a notarisation ticket, and proving one actually landed.
# Sourced by bundle.sh (at build time), notarise-release.sh (afterwards, when
# Apple's queue was down at build time) and release.sh (as the gate before a
# tag is pushed). One copy of each, because the retry rules and the checks
# below are easy to get subtly wrong and a second copy would drift.
#
# Env:
#   SIGN_ID          codesign identity — see find_sign_id
#   NOTARY_PROFILE   notarytool keychain profile           (default thegit)
#   NOTARY_TIMEOUT   how long to wait for one verdict          (default 2h)
#   NOTARY_RETRIES   fresh submissions before giving up        (default 1)

NOTARY_PROFILE="${NOTARY_PROFILE:-thegit}"
# Wait long, resubmit rarely. Verdicts for this team arrive in hours, not
# the minutes the documentation leads you to expect: on 2026-08-12, its first
# day of notarising anything, a submission at 08:42Z was accepted around
# 11:20Z and four others sat unanswered for eight hours. Nothing was wrong
# with Apple that morning or with the builds — see docs/notarisation.md.
#
# Which makes a short timeout with retries the wrong shape: a resubmission
# does not jump the queue, it adds one more item to a slow one, and the
# submission it walked away from gets accepted anyway with nobody waiting to
# staple it. That is how v0.10.7 shipped unstapled with three accepted
# submissions sitting on Apple's servers.
#
# Nothing is lost by giving up on the wait, either: the ticket keeps, and
# the staple-first path in notarise() picks it up on the next run in under a
# second. Ctrl-C and come back later is a supported way to use this.
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-2h}"
NOTARY_RETRIES="${NOTARY_RETRIES:-1}"

# Matched by name rather than hash so the script keeps working when the
# certificate is renewed — Developer ID certs expire every five years and the
# replacement has a different hash but the same subject. Prints nothing when
# there is no certificate, which callers read as "ad-hoc".
#
# `sed -n 1p` rather than `head -1` here and below: head exits the moment it
# has its line, and every caller runs under `set -o pipefail`, where the
# SIGPIPE that kills the still-writing producer becomes the pipeline's exit
# status. sed reads to EOF, so there is nobody to kill.
find_sign_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sed -n 1p
}

# The verdict is read out of the output rather than the exit status on
# purpose: `notarytool submit --wait` exits 0 when the wait times out, so a
# script that trusts the exit code ships an unnotarised build believing it
# succeeded. "status: Accepted" is the only thing that means accepted.
notarise() { # <path to submit> <path to staple>
    local log attempt=1 id

    # Ask for the ticket before queueing for one. Apple keys tickets to the
    # code directory hash and keeps them, and notarising a container issues
    # them for the code inside it too — so an app that travelled inside an
    # accepted DMG already has a ticket waiting, and so does anything a
    # previous run submitted before it gave up on the wait. One cheap round
    # trip, and when it hits there is nothing to wait for at all.
    #
    # This is not a theoretical saving: v0.10.7 needed no submission at all.
    # Both its tickets had been sitting on Apple's servers since the DMG was
    # accepted that morning, while the release shipped unstapled and later
    # runs queued for hours behind a stalled notary service to ask for
    # something they already had.
    if xcrun stapler staple "$2" >/dev/null 2>&1; then
        echo "==> $(basename "$2") was notarised already — stapled the ticket Apple had"
        return 0
    fi

    log="$(mktemp)"
    while :; do
        echo "==> Notarising $(basename "$1") (attempt $attempt of $NOTARY_RETRIES)"
        echo "    Ctrl-C is safe: the submission survives, and re-running this"
        echo "    staples the ticket in about a second once Apple has answered."
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
            --wait --timeout "$NOTARY_TIMEOUT" 2>&1 | tee "$log" || true
        id="$(sed -n 's/^ *id: \(.*\)/\1/p' "$log" | sed -n 1p)"

        if grep -q "status: Accepted" "$log"; then
            rm -f "$log"
            # Checked, not fired and forgotten. At the `if ! notarise ...`
            # call site bash suspends errexit for the whole function, so an
            # unchecked staple falls straight through to `return 0` and
            # reports success for a build that carries no local ticket —
            # which is exactly how v0.10.7 shipped after Apple had already
            # accepted it twice.
            xcrun stapler staple "$2" || return 1
            return 0
        fi

        # Apple saying no is not Apple saying nothing. A rejected build fails
        # identically on every retry, so stop and point at the log that says
        # which check it tripped.
        if grep -q "status: Invalid" "$log"; then
            echo "    Apple rejected this build. Why:"
            echo "      xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
            rm -f "$log"
            return 1
        fi

        # Anything else is the queue swallowing the submission — it happens,
        # and the cure is a fresh submission rather than a longer wait.
        if [ "$attempt" -ge "$NOTARY_RETRIES" ]; then
            echo "    no verdict after $NOTARY_RETRIES attempt(s) of $NOTARY_TIMEOUT each."
            echo "    Nothing is lost — the submission is still queued, and Apple keeps"
            echo "    the ticket once it lands. Watch for it, then just run this again:"
            echo "      xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
            rm -f "$log"
            return 1
        fi
        echo "    no verdict within $NOTARY_TIMEOUT (submission $id) — resubmitting"
        attempt=$((attempt + 1))
    done
}

# The same thing as notarise(), for a queue you can't wait out. Submits
# without blocking, remembers the submission id, and picks up where it left
# off next time — so one command run three times gets a release notarised
# without anybody sitting in front of a terminal for six hours.
#
# The remembered id is the point. Resubmitting doesn't jump the queue, it
# adds one more item to a slow one, so a "check again" that blindly
# submitted would make things worse every time it was run.
#
# State lives next to the artefacts in dist/, which is gitignored: this is a
# local, one-machine workflow, and a ticket is only useful on the machine
# holding the bytes it belongs to.
#
#   0  stapled, this leg is done
#   2  submitted or still queued — nothing to do but come back
#   1  rejected, or something is wrong
notarise_async() { # <path to submit> <path to staple> <state file>
    local submit="$1" staple="$2" state="$3" id out status name
    name="$(basename "$staple")"

    if xcrun stapler staple "$staple" >/dev/null 2>&1; then
        echo "    $name — ticket stapled"
        rm -f "$state"
        return 0
    fi

    if [ -f "$state" ]; then
        id="$(cat "$state")"
        out="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true)"
        status="$(printf '%s\n' "$out" | sed -n 's/^ *status: //p' | sed -n 1p)"
        case "$status" in
            Accepted)
                # The staple above should have caught this; if it didn't, the
                # ticket landed between the two calls or the first attempt hit
                # a blip. Either way it is worth one more try before giving up.
                xcrun stapler staple "$staple" || return 1
                echo "    $name — ticket stapled"
                rm -f "$state"
                return 0 ;;
            Invalid|Rejected)
                echo "    $name — Apple rejected submission $id. Why:"
                echo "      xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
                rm -f "$state"
                return 1 ;;
            "")
                echo "    $name — cannot read submission $id:"
                printf '%s\n' "$out" | sed 's/^/      /'
                return 1 ;;
            *)
                echo "    $name — submission $id is still $status"
                return 2 ;;
        esac
    fi

    echo "    $name — submitting (not waiting for the verdict)"
    out="$(xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true)"
    id="$(printf '%s\n' "$out" | sed -n 's/^ *id: //p' | sed -n 1p)"
    if [ -z "$id" ]; then
        echo "    $name — the submission was not accepted:"
        printf '%s\n' "$out" | sed 's/^/      /'
        return 1
    fi
    mkdir -p "$(dirname "$state")"
    printf '%s\n' "$id" > "$state"
    echo "    $name — queued as $id"
    return 2
}

# What `codesign --verify` proves is that a signature is internally
# consistent: an ad-hoc bundle passes it, and so does a Developer ID bundle
# Apple has never seen. `spctl` looks stricter and isn't — it asks Apple over
# the network, so a bundle whose ticket was never stapled comes back
# "accepted" here and is refused on a Mac that is offline. The only copy of
# the ticket that travels with a download is the one inside the bundle, and
# `syspolicy_check distribution` is the check that reads it.
verify_distribution() { # <path to a .app or a .dmg> <execute|open>
    local path="$1" rc=0 out
    local -a assess
    case "$2" in
        execute) assess=(--type execute) ;;
        open)    assess=(--type open --context context:primary-signature) ;;
        *) echo "verify_distribution: unknown kind '$2'" >&2; return 1 ;;
    esac

    echo "==> Checking $(basename "$path") the way a downloader's Mac will"

    if ! out="$(codesign --verify --strict --verbose=2 "$path" 2>&1)"; then
        echo "    !! the signature does not verify"
        echo "$out" | sed 's/^/       /'
        rc=1
    fi
    if ! xcrun stapler validate "$path" >/dev/null 2>&1; then
        echo "    !! no notarisation ticket is stapled to it"
        rc=1
    fi
    if ! out="$(spctl --assess "${assess[@]}" --verbose=4 "$path" 2>&1)"; then
        echo "    !! Gatekeeper rejects it"
        echo "$out" | sed 's/^/       /'
        rc=1
    fi
    # macOS 14 and up, so it is guarded rather than assumed. This is the one
    # check that reads the ticket inside the bundle instead of asking Apple,
    # which makes it the one that fails on the unstapled build the two above
    # are happy to wave through.
    if [ "$2" = "execute" ] && command -v syspolicy_check >/dev/null 2>&1; then
        if ! out="$(syspolicy_check distribution "$path" 2>&1)"; then
            echo "    !! syspolicy_check says this would not distribute:"
            echo "$out" | sed 's/^/       /'
            rc=1
        fi
    fi

    [ "$rc" = 0 ] && echo "    signed, notarised, stapled, Gatekeeper-clean"
    return "$rc"
}

# A ticket on the DMG only covers the DMG. Drag the app to /Applications,
# throw the image away, and what Gatekeeper reads on a Mac that is offline is
# the ticket inside the bundle — so anything gating a release has to open the
# image and look at the app that people actually keep.
verify_dmg_contents() { # <dmg>
    local mnt rc=0 app
    mnt="$(mktemp -d)"
    if ! hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$1"; then
        rmdir "$mnt" 2>/dev/null || true
        echo "    !! $(basename "$1") will not mount"
        return 1
    fi
    app="$(find "$mnt" -maxdepth 1 -name '*.app' | sed -n 1p)"
    if [ -n "$app" ]; then
        verify_distribution "$app" execute || rc=1
    else
        echo "    !! no .app inside $(basename "$1")"
        rc=1
    fi
    hdiutil detach -quiet "$mnt" >/dev/null 2>&1 || true
    rmdir "$mnt" 2>/dev/null || true
    return "$rc"
}

# The image is assembled here rather than inline in bundle.sh because
# notarise-release.sh has to build it too: a ticket cannot be stapled into a
# read-only image after the fact, so backfilling the app's ticket means
# making the image again around the stapled bundle.
build_dmg() { # <app> <dmg> <volume name> <sign id, or - for ad-hoc>
    local stage
    stage="$(dirname "$2")/dmg"
    rm -rf "$stage"
    mkdir -p "$stage"
    # ditto rather than cp -R: by the time this runs the bundle is signed and
    # usually stapled, and ditto is the copy that carries all of that across
    # intact rather than mostly intact.
    ditto "$1" "$stage/$(basename "$1")"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$3" -srcfolder "$stage" \
        -ov -format UDZO "$2"
    rm -rf "$stage"
    if [ "$4" != "-" ]; then
        codesign --force --timestamp --sign "$4" "$2"
    fi
}
