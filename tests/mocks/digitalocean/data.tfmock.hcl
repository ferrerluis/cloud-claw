mock_resource "digitalocean_droplet" {
  defaults = {
    id           = 4242
    ipv4_address = "203.0.113.20"
  }
}

mock_resource "digitalocean_volume" {
  defaults = {
    id = "do-volume-agentstacktest"
  }
}
