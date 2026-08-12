# Notarisation, shared by bundle.sh (at build time) and
# notarise-release.sh (afterwards, when Apple's queue was down at build
# time). Sourced, not run — there is one copy of this because the retry
# rules below are easy to get subtly wrong and a second copy would drift.
#
# Env:
#   NOTARY_PROFILE   notarytool keychain profile           (default thegit)
#   NOTARY_TIMEOUT   how long to wait for one verdict         (default 20m)
#   NOTARY_RETRIES   fresh submissions before giving up        (default 3)

NOTARY_PROFILE="${NOTARY_PROFILE:-thegit}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-20m}"
NOTARY_RETRIES="${NOTARY_RETRIES:-3}"

# The verdict is read out of the output rather than the exit status on
# purpose: `notarytool submit --wait` exits 0 when the wait times out, so a
# script that trusts the exit code ships an unnotarised build believing it
# succeeded. "status: Accepted" is the only thing that means accepted.
notarise() { # <path to submit> <path to staple>
    local log attempt=1 id
    log="$(mktemp)"
    while :; do
        echo "==> Notarising $(basename "$1") (attempt $attempt of $NOTARY_RETRIES)"
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
            --wait --timeout "$NOTARY_TIMEOUT" 2>&1 | tee "$log" || true
        id="$(sed -n 's/^ *id: \(.*\)/\1/p' "$log" | head -1)"

        if grep -q "status: Accepted" "$log"; then
            rm -f "$log"
            xcrun stapler staple "$2"
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
            echo "    no verdict after $NOTARY_RETRIES attempts of $NOTARY_TIMEOUT each."
            echo "    The submissions are not lost; check them later with:"
            echo "      xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
            rm -f "$log"
            return 1
        fi
        echo "    no verdict within $NOTARY_TIMEOUT (submission $id) — resubmitting"
        attempt=$((attempt + 1))
    done
}
