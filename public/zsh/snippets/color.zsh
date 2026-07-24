# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et
# Source: https://github.com/molovo/color
# License: MIT — Copyright (c) 2015 Joe Letchford
# Maintained by z-shell/src — https://github.com/z-shell/src

function color() {
  local color=$1 style=$2 b=0

  shift

  case $style in
    bold|b)           b=1; shift ;;
    italic|i)         b=2; shift ;;
    underline|u)      b=4; shift ;;
    inverse|in)       b=7; shift ;;
    strikethrough|s)  b=9; shift ;;
  esac

  case $color in
    black|b)    echo "\033[${b};30m${@}\033[0;m" ;;
    red|r)      echo "\033[${b};31m${@}\033[0;m" ;;
    green|g)    echo "\033[${b};32m${@}\033[0;m" ;;
    yellow|y)   echo "\033[${b};33m${@}\033[0;m" ;;
    blue|bl)    echo "\033[${b};34m${@}\033[0;m" ;;
    magenta|m)  echo "\033[${b};35m${@}\033[0;m" ;;
    cyan|c)     echo "\033[${b};36m${@}\033[0;m" ;;
    white|w)    echo "\033[${b};37m${@}\033[0;m" ;;
    *)          echo "\033[${b};38;5;$(( ${color} ))m${@}\033[0;m" ;;
  esac
}

color "$@"
