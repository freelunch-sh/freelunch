# The deploy of sample-custom: sends the image somewhere api.yaml can't describe.
api_custom_demo_deploy() { # <provider> <vars file>
  echo "uploaded $(jq -r .image "$2") for $(jq -r .id "$2")" > "$FAKE_API_DIR/custom"
}
