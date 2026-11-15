# bpm dependency walks
#
# this is written in awk instead of shell because its WAY faster
# and honestly quite a bit more legible
#
# input: a table, one package per line (index_table, db_table)
#   1 name 2 pkg_ver 3 use 4 depends 5 make_depends 6 use_depends 7 dir 8 flags
#
# flags: ? = in no repo, i = installed , c = binary package is current
#   e = explicitly installed, k = never orphaned, p = pinned
#
# awk -v mode=<mode> -v args=<list> -v extra=<list> -v force=0|1
#   -v buildroot=<BPM_BUILDROOT> -v bootstrap=<BPM_BOOTSTRAP>
#
# template table:
#   order     <named>          install order: dependencies first, installed ones skipped
#   closure   <pkgs>           runtime closure, installed or not
#   versions  <pkgs>           name|pkg_ver|use for each
#   unmet     <pkgs> <flag>    members of the runtime closure without <flag>
#   plan      <order> <named>  what has to be built, in build order, as name|pkg_ver|role
#   hostdeps  <plan>           pkg|missing... where a host build lacks installed make_depends
#   usedeps   <pkgs> <conf>    fails on the first use_depends entry that isn't met
# installed table:
#   rdeps     <pkg> <omitted>  installed packages that depend on <pkg>
#   held      <pkgs>           dependant->pkg for everything outside <pkgs> still needing one
#   orphans   <omitted>        installed packages nothing explicit leads to
#   remove    <pkgs>           removal order: dependants before what they depend on
#
# an error is printed as one line with exit status 1

BEGIN { FS = "|" }

{
    ver[$1] = $2; use[$1] = $3; deps[$1] = $4; mdeps[$1] = $5; udeps[$1] = $6
    flags[$1] = $8
    rows[++nrows] = $1
}

function has(name, flag) { return index(flags[name], flag) > 0 }
function fail(text) { print text; exit 1 }

function need(name, parent) {
    if (!(name in ver) || has(name, "?"))
        fail("package '" name "' not found in any repository" (parent != "" ? " (required by " parent ")" : ""))
}

# set[word] = 1 for every word in a space separated list
function toset(list, set, n, w, i) {
    n = split(list, w, " ")
    for (i = 1; i <= n; i++) set[w[i]] = 1
}

function contains(list, word) { return index(" " list " ", " " word " ") > 0 }

# on the host when theres no buildroot or while bpm is bootstrapping itself
function hostbuilt(name) { return buildroot == "" || contains(bootstrap, name) }

# post-order over depends, installed deps arent walked into
# packages specifically listed are
function order_walk(name, parent, n, d, i) {
    if (name in oseen) return
    oseen[name] = 1
    need(name, parent)
    n = split(deps[name], d, " ")
    for (i = 1; i <= n; i++)
        if (!(d[i] in ver) || !has(d[i], "i")) order_walk(d[i], name)
    oout = oout " " name
}

function closure_walk(name, parent, n, d, i) {
    if (name in cseen) return
    cseen[name] = 1
    need(name, parent)
    n = split(deps[name], d, " ")
    for (i = 1; i <= n; i++) closure_walk(d[i], name)
    cout = cout " " name
}

# runtime closure of a list as " a b c" (note the space at the start)
function closure(list, parent, n, w, i) {
    split("", cseen); cout = ""
    n = split(list, w, " ")
    for (i = 1; i <= n; i++) closure_walk(w[i], parent)
    return cout
}

# the buildroot has the runtime closure of make_depends and
# each of those needs to be built first, host builds need them
# installed instead
function plan_walk(name, top, n, c, i, members) {
    if (name in building) fail(name ": dependency cycle in make_depends")
    if (name in pseen) return
    pseen[name] = 1
    if ((!force || !top) && has(name, "c")) return
    if (!hostbuilt(name)) {
        n = split(mdeps[name], c, " ")
        for (i = 1; i <= n; i++) need(c[i], name)
        members = closure(mdeps[name], name)
        building[name] = 1
        n = split(members, c, " ")
        for (i = 1; i <= n; i++) plan_walk(c[i], 0)
        delete building[name]
    }
    plan[++nplan] = name
}

# packages to keep + whatever they need
function keep_walk(name, n, d, i) {
    if (name in kept || !(name in ver) || name in omitted) return
    kept[name] = 1
    n = split(deps[name], d, " ")
    for (i = 1; i <= n; i++) keep_walk(d[i])
}

function remove_walk(name, n, d, i) {
    if (name in rseen) return
    rseen[name] = 1
    n = split(deps[name], d, " ")
    for (i = 1; i <= n; i++) if (d[i] in rset) remove_walk(d[i])
    rorder[++nr] = name
}

END {
    n = split(args, arg, " ")

    if (mode == "order") {
        for (i = 1; i <= n; i++) order_walk(arg[i], "")
        print substr(oout, 2)
    }
    else if (mode == "closure") {
        print substr(closure(args, ""), 2)
    }
    else if (mode == "versions") {
        for (i = 1; i <= n; i++) print arg[i] "|" ver[arg[i]] "|" use[arg[i]]
    }
    else if (mode == "unmet") {
        m = split(closure(args, ""), c, " ")
        for (i = 1; i <= m; i++) if (!has(c[i], extra)) printf "%s%s", (found++ ? " " : ""), c[i]
        if (found) print ""
    }
    else if (mode == "plan") {
        toset(extra, named); toset(args, inorder)
        for (i = 1; i <= n; i++) plan_walk(arg[i], 1)
        for (i = 1; i <= nplan; i++) {
            p = plan[i]
            role = (p in named) ? "" : (p in inorder) ? "dependency" : "make dependency, not installed"
            print p "|" ver[p] "|" role
        }
    }
    else if (mode == "hostdeps") {
        for (i = 1; i <= n; i++) {
            if (!hostbuilt(arg[i])) continue
            missing = ""
            m = split(closure(mdeps[arg[i]], arg[i]), c, " ")
            for (j = 1; j <= m; j++) if (!has(c[j], "i")) missing = missing " " c[j]
            if (missing != "") print arg[i] "|" substr(missing, 2)
        }
    }
    else if (mode == "usedeps") {
        for (i = 1; i <= n; i++) {
            m = split(udeps[arg[i]], u, " ")
            for (j = 1; j <= m; j++) {
                dep = u[j]; sub(/:.*/, "", dep)
                flag = u[j]; sub(/^[^:]*:/, "", flag)
                if (!(dep in ver) || has(dep, "?") || contains(use[dep], flag)) continue
                fail(arg[i] " needs " dep " built with use flag '" flag "'\n    add '" dep " " flag "' to " extra)
            }
        }
    }
    else if (mode == "rdeps") {
        toset(extra, omitted)
        for (r = 1; r <= nrows; r++) {
            p = rows[r]
            if (p != args && !(p in omitted) && contains(deps[p], args)) print p
        }
    }
    else if (mode == "held") {
        toset(args, leaving)
        for (r = 1; r <= nrows; r++) {
            p = rows[r]
            if (p in leaving) continue
            m = split(deps[p], d, " ")
            for (j = 1; j <= m; j++) if (d[j] in leaving) printf "%s%s->%s", (found++ ? " " : ""), p, d[j]
        }
        if (found) print ""
    }
    else if (mode == "orphans") {
        toset(args, omitted)
        for (r = 1; r <= nrows; r++)
            if (has(rows[r], "e") || has(rows[r], "k")) keep_walk(rows[r])
        for (r = 1; r <= nrows; r++)
            if (!(rows[r] in kept) && !(rows[r] in omitted)) print rows[r]
    }
    else if (mode == "remove") {
        toset(args, rset)
        for (i = 1; i <= n; i++) remove_walk(arg[i])
        for (i = nr; i >= 1; i--) printf "%s%s", rorder[i], (i > 1 ? " " : "\n")
    }
    else fail("graph.awk: unknown mode " mode)
}
