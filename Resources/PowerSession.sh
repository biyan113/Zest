#!/bin/sh
# Called only after macOS administrator authorization. No persistent daemon is installed.
set -eu
umask 077
host_pid=$1
lease=$2
lock=/var/run/app.zest.monitor.awake
case "$host_pid" in ''|*[!0-9]*) exit 64 ;; esac

if [ "${3:-}" = '--watch' ]; then
    previous=$4
    restore() {
        /usr/bin/pmset -a disablesleep "$previous" || exit 1
        /bin/rm -f "$lock/pid" "$lock/previous"
        /bin/rmdir "$lock"
    }
    trap restore EXIT
    trap 'exit 0' HUP INT TERM
    while /bin/kill -0 "$host_pid" 2>/dev/null && [ -f "$lease" ]; do
        /bin/sleep 1
    done
    exit 0
fi

if ! /bin/mkdir "$lock" 2>/dev/null; then
    watcher=$(/bin/cat "$lock/pid" 2>/dev/null || true)
    case "$watcher" in
        ''|*[!0-9]*) echo 'Power session needs manual recovery.' >&2; exit 1 ;;
    esac
    if /bin/kill -0 "$watcher" 2>/dev/null; then
        echo 'Another keep-awake session is active.' >&2
        exit 1
    fi
    # A watcher killed without running its trap leaves the original setting here.
    previous=$(/bin/cat "$lock/previous")
    case "$previous" in 0|1) ;; *) exit 1 ;; esac
    /usr/bin/pmset -a disablesleep "$previous"
    /bin/rm -f "$lock/pid" "$lock/previous"
    /bin/rmdir "$lock"
    /bin/mkdir "$lock"
fi
echo "$$" > "$lock/pid"
previous=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2; exit}')
case "$previous" in
    0|1) ;;
    *) /bin/rm -f "$lock/pid"; /bin/rmdir "$lock"; echo 'Unable to read the original sleep setting.' >&2; exit 1 ;;
esac
echo "$previous" > "$lock/previous"
rollback() {
    /usr/bin/pmset -a disablesleep "$previous"
    /bin/rm -f "$lock/pid" "$lock/previous"
    /bin/rmdir "$lock"
}
trap rollback EXIT
/usr/bin/pmset -a disablesleep 1
/usr/bin/nohup /bin/sh "$0" "$host_pid" "$lease" --watch "$previous" </dev/null >/dev/null 2>&1 &
watcher=$!
echo "$watcher" > "$lock/pid"
/bin/kill -0 "$watcher"
trap - EXIT
