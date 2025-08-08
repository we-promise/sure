#!/bin/bash

########
# GitHub
########

function git_branch() {
    local branch
    branch="$(git symbolic-ref --short HEAD 2> /dev/null)"
    if [[ -n "$branch" ]]; then
        echo -n "$branch"
        return 0
    fi
    return 1
}

function in_git_dir() {
  git rev-parse --is-inside-work-tree > /dev/null 2>&1
}

function git_name() {
  git config user.name 2> /dev/null
}

function git_has_diff() {
  git diff --quiet HEAD 2> /dev/null
}

function git_status_marker() {
  if in_git_dir; then
    git_has_diff || echo -n ' *'
  fi
}

########
# PROMPT
########

export WHITE='\[\033[1;37m\]'
export LIGHT_GREEN='\[\033[0;32m\]'
export LIGHT_BLUE='\[\033[0;94m\]'
export LIGHT_BLUE_BOLD='\[\033[1;94m\]'
export RED_BOLD='\[\033[1;31m\]'
export YELLOW_BOLD='\[\033[1;33m\]'
export COLOUR_OFF='\[\033[0m\]'

function prompt_command() {
  local P=""
  P="[\$?] "
  P+="${LIGHT_GREEN}$(git_name || echo -n \$USER)"
  P+="${WHITE} ➜ "
  P+="${LIGHT_BLUE_BOLD}\w"

  if in_git_dir; then
    P+=" ${LIGHT_BLUE}("
    P+="${RED_BOLD}\$(git_branch)"
    P+="${YELLOW_BOLD}\$(git_status_marker)"
    P+="${LIGHT_BLUE})"
    P+="${COLOUR_OFF} "
  else
    P+="${COLOUR_OFF}"
  fi

  P+='\$ '
  export PS1="$P"
}

export PROMPT_COMMAND='prompt_command'
