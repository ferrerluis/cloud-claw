mock_resource "hcloud_server" {
  defaults = {
    id           = 31337
    ipv4_address = "203.0.113.30"
  }
}

mock_resource "hcloud_volume" {
  defaults = {
    id = 31338
  }
}
