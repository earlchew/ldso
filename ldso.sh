#!/bin/dash

# Copyright (c) 2016, Earl Chew
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the names of the authors of source code nor the names
#       of the contributors to the source code may be used to endorse or
#       promote products derived from this software without specific
#       prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL EARL CHEW BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

set -eu

# Shared Library Interpreter Trampoline
#
# This script is used to locate a shared library interpreter used to
# run a program. Normally the absolute path to a shared library interpreter
# is embedded in the ELF header and can be displayed using "readelf -l":
#
#  INTERP         0x000134 0x08047134 0x08047134 0x00013 0x00013 R   0x1
#      [Requesting program interpreter: /lib/ld-linux.so.2]
#
# When a turn-key application is packaged, the location of its shared
# libraries is discovered using the $ORIGIN key word in DT_RPATH. This
# script allows the location of the shared library interpreter to be
# discovered using the same mechanism:
#
#  INTERP         0x000154 0x08048154 0x08048154 0x0000e 0x0000e R   0x1
#      [Requesting program interpreter: ld-linux.so.2]
#
# In this case, the shared library interpreter is sought using the
# information embedded in DT_RPATH:
#
# 0x0000000f (RPATH)                      Library rpath: [$ORIGIN/../lib]
#
# The resulting program is run using the discovered shared librar interpreter.

[ -z "${0##*/*}" ] || exec "$PWD/$0" "$@"

debug()
{
    [ -z "${LDSO_DEBUG++}" ] || { eval "$1" ; } >&2
}

print()
{
    IFS=' ' printf "%s\n" "$*"
}

die()
{
    print "$0: $1" >&2
    exit 1
}

quote()
{
    print "$1" | { # Credit: http://www.etalabs.net/sh_tricks.html
        set --                         # String may have newlines
        set -- "$@" -e "s/'/'\\\\''/g" # Quote all single quotes
        set -- "$@" -e "1s/^/'/"       # Begin with single quote
        set -- "$@" -e "\$s/\$/'/"     # End with single quote
        sed "$@"
    }
}

quoteargs()
{
    while [ $# -ne 0 ] ; do
        quote "$1"
        shift
    done
}

rpath()
{
    SO_LIBPATH=$1
    EXEC_PATH=$2

    while IFS= read -r REPLY ; do
        ! [ -z "$REPLY" ] || continue
        case "$REPLY" in
            *'(RPATH)'* )
                SO_RPATH=$REPLY
                SO_RPATH="${SO_RPATH##*\[}"
                SO_RPATH="${SO_RPATH%\]*}"
                ;;
            *'Requesting program interpreter'* )
                SO_INTERP=$REPLY
                SO_INTERP="${SO_INTERP#*: }"
                SO_INTERP="${SO_INTERP%]*}"
                ;;
        esac
    done <<- EOF
	$(readelf -ld -- "$EXEC_PATH")
	EOF

    [ -z "${EXEC_PATH##/*}" ] || EXEC_PATH="$PWD/$EXEC_PATH"

    # Only proceed if DT_RPATH contains $ORIGIN, and PT_INTERP does not
    # use an absolute pathname.

    [ -n "$SO_RPATH" -a x"${SO_RPATH#\$ORIGIN}" != x"$SO_RPATH" ] ||
    [ -n "$SO_INTERP" -a -n "${SO_INTERP##/*}" ]                  ||
    [ -x "$EXEC_PATH" ]                                           || {
        print "."
        return 0
    }

    # Replace all instances of $ORIGIN in SO_RPATH with the
    # directory containing the executable.

    while [ -n "$SO_RPATH" -a -z "${SO_RPATH##*\$ORIGIN*}" ] ; do
     SO_RPATH="${SO_RPATH%%\$ORIGIN*}${EXEC_PATH%/*}${SO_RPATH#*\$ORIGIN}"
    done

    LDSO=$(
        IFS=:
        set -- "${EXEC_PATH%/*}"
        set -- "$@" $SO_RPATH
        set -- "$@" ${LD_LIBRARY_PATH+$LD_LIBRARY_PATH}
        while [ $# -ne 0 ] ; do
            ! [ -x "$1/$SO_INTERP" ] || { print "$1/$SO_INTERP" ; break ; }
            shift
        done
    )

    [ -n "$LDSO" ] || die "Unable to find ELF interpreter $SO_INTERP"

    print "$LDSO"
    return 0
}

# Expect the program name to be a symbolic link that resolves to secondary
# symbolic link that points at the this script:
#
#   Primary Link          Secondary Link                   Script
#   /usr/local/bin/app -> /usr/local/pkg/app/bin/app.sh -> /usr/local/bin/ldso
#
#                        /usr/local/pkg/app/bin/app
#                        Application Binary
#
# The extension is stripped off the name of the secondary link to obtain
# the name of the underlying binary.

exepath()
{
    [ -h "$1" ] || die "Symbolic link expected at $1"

    set -- "$(readlink "$1")"

    [ -z "${1##/*}" ]    || set -- "${0%/*}/$1}"
    [ -z "${1##*/*.*}" ] || die "File extension expected at $1"

    print "${1%.*}"
}

debug 'set -x'

set -- "$(exepath "$0")" "$@"
[ -n "$1" ] || exit 1

[ -x "$1" ] || die "Executable expected at $1"

set -- "$(
        ldconfig -XNv 2>&- |
            sed -ne '/:/{s,:.*,,;p;}' |
            sed -n -e '1{x;d;}' -e 'x;G;x' -e '${x;s,\n,:,g;p;}'
    )${LD_LIBRARY_PATH+:$LD_LIBRARY_PATH}" "$@"

set -- "$(rpath "$@")" "$@"
[ -n "$1" ] || exit 1

if [ x"$1" = x. ] ; then
    shift 2
else
    eval set -- $(quote "$2") $(quote "$1") $(shift 2 ; quoteargs "$@")
    export LD_LIBRARY_PATH=$1
    shift
fi

exec "$@"
die "Unable to execute $1"
