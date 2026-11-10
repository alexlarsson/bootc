# number: 53
# extra:
#   export_image: true
#   skip_if_ostree: true
# tmt:
#   summary: Apply OCI delta switch and upgrade through unified composefs storage
#   duration: 30m
#   adjust:
#     - when: distro != fedora
#       enabled: false
#       because: oci-delta is packaged in Fedora
#     - when: distro == fedora-43
#       enabled: false
#       because: oci-delta is not packaged for Fedora 43
#     - when: boot_type == uki and seal_state == sealed
#       enabled: false
#       because: the guest-local UKI builder produces unsigned images
#

def main [] {
    with-env { BOOTC_test_unified_delta: "1" } {
        nu ($env.FILE_PWD | path join "test-switch-from-delta.nu")
    }
}
