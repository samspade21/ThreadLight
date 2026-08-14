# Sourced by release builds only. Loads Apple signing configuration from an
# optional, gitignored .signing.env so a maintainer Mac does not have to export
# CODE_SIGN_IDENTITY and NOTARY_PROFILE for every build. Values already present
# in the environment always win, so CI keeps full control. See .signing.env.example.
[[ -n "${PROJECT_DIR:-}" ]] || {
    print -u2 "signing-env.sh requires PROJECT_DIR."
    exit 2
}

SIGNING_ENV_FILE=${THREADLIGHT_SIGNING_ENV:-"$PROJECT_DIR/.signing.env"}
if [[ -f "$SIGNING_ENV_FILE" ]]; then
    SIGNING_ENV_PRESET_IDENTITY=${CODE_SIGN_IDENTITY:-}
    SIGNING_ENV_PRESET_PROFILE=${NOTARY_PROFILE:-}
    source "$SIGNING_ENV_FILE"
    if [[ -n "$SIGNING_ENV_PRESET_IDENTITY" ]]; then
        CODE_SIGN_IDENTITY=$SIGNING_ENV_PRESET_IDENTITY
    fi
    if [[ -n "$SIGNING_ENV_PRESET_PROFILE" ]]; then
        NOTARY_PROFILE=$SIGNING_ENV_PRESET_PROFILE
    fi
    unset SIGNING_ENV_PRESET_IDENTITY SIGNING_ENV_PRESET_PROFILE
fi

export CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:-}
export NOTARY_PROFILE=${NOTARY_PROFILE:-}
