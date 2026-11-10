# number: 51
# extra:
#   export_image: true
# tmt:
#   summary: Switch to a derived image using an OCI delta and verify after reboot
#   duration: 30m
#   adjust:
#     - when: distro != fedora
#       enabled: false
#       because: oci-delta is packaged in Fedora
#     - when: distro == fedora-43
#       enabled: false
#       because: oci-delta is not packaged for Fedora 43 (https://github.com/bootc-dev/bootc/issues/2604)
#     - when: boot_type == uki and seal_state == sealed
#       enabled: false
#       because: the guest-local UKI builder produces unsigned images
#
use std assert
use tap.nu

const image = "localhost/bootc-delta-target:latest"
const delta = "/var/tmp/image-1-to-2.oci-delta"
const state = "/var/tmp/bootc-delta-state.json"
const marker = "/usr/share/testing-bootc-delta"

def verify_unified_storage [expected] {
    let images = bootc image cmd list --all --no-trunc --format json | from json
    assert ($images | any {|entry| $entry.Digest == $expected.digest})
    assert ($images | any {|entry| $entry.Id == $expected.source_id}) "Delta source must remain in storage for rollback"
    let content = podman --storage-opt=additionalimagestore=/usr/lib/bootc/storage run --rm --pull=never --network=none --entrypoint /usr/bin/cat $expected.image $marker
    assert equal ($content | str trim) $expected.marker
}

def initial_build [] {
    tap begin "switch from OCI delta"
    assert (not ($marker | path exists))
    let st = bootc status --json | from json
    let unified = $env.BOOTC_test_unified_delta? == "1"
    let source_id = if $unified {
        assert (tap is_composefs)
        unshare --net bootc image set-unified
        bootc image cmd list --no-trunc --filter $"reference=($st.status.booted.image.image.image)" --format json | from json | first | get Id
    } else { "" }

    if not (tap is_composefs) {
        let automounted = (
            do { ^findmnt --mountpoint /boot --types autofs --noheadings } | complete
        ).exit_code == 0
        if $automounted {
            # An expired /boot breaks ostree finalization: https://github.com/bootc-dev/bootc/issues/2402
            let dropin = "/etc/systemd/system/boot.automount.d/bootc-delta-test.conf"
            mkdir ($dropin | path dirname)
            "[Automount]\nTimeoutIdleSec=0\n" | save $dropin
            systemctl daemon-reload
            systemctl restart boot.automount
        }
    }

    let source_archive = $env.BOOTC_source_image_archive? | default "/sysroot/bootc-source.oci.tar"
    assert ($source_archive | path exists) $"Missing source image archive: ($source_archive)"
    skopeo copy $"oci-archive:($source_archive)" containers-storage:localhost/bootc

    (tap make_uki_containerfile $"
        FROM localhost/bootc as base
        RUN echo delta-upgrade > ($marker)
    ") | save Dockerfile
    podman build --network=none -t $image .

    let target = skopeo inspect $"containers-storage:($image)" | from json
    let reference = if $unified { $image } else { $"localhost/bootc-delta-target@($target.Digest)" }
    assert ($target.Digest != $st.status.booted.image.imageDigest)

    oci-delta create $"oci-archive:($source_archive)" $"containers-storage:($image)" $delta
    # Keep the target available only through the delta.
    podman rmi $image

    {
        image: $reference
        digest: $target.Digest
        composefs: (tap is_composefs)
        unified: $unified
        source_id: $source_id
        marker: "delta-upgrade"
    } | to json | save $state

    unshare --net bootc switch --from-delta $delta $reference
    let staged = (bootc status --json | from json).status.staged.image
    assert equal $staged.image.transport registry
    assert equal $staged.image.image $reference
    assert equal $staged.imageDigest $target.Digest
    if $unified { verify_unified_storage (open $state) }
    assert (not ($marker | path exists))
    tmt-reboot
}

def verify_delta [] {
    let expected = open $state
    let booted = (bootc status --json | from json).status.booted.image
    assert equal $booted.image.transport registry
    assert equal $booted.image.image $expected.image
    assert equal $booted.imageDigest $expected.digest
    assert equal (open $marker | str trim) $expected.marker
    assert equal (tap is_composefs) $expected.composefs
    if $expected.unified { verify_unified_storage $expected }
    bootc internals fsck
    tap ok
}

def upgrade_delta [] {
    tap begin "upgrade a mutable tag from an OCI delta in unified storage"
    let source = bootc image cmd list --no-trunc --filter $"reference=($image)" --format json | from json | first
    let source_archive = "/var/tmp/bootc-unified-delta-source.oci.tar"
    bootc image cmd push $image $"oci-archive:($source_archive)"

    let td = mktemp -d
    cd $td
    (tap make_uki_containerfile $"
        FROM ($image) as base
        RUN echo delta-unified-upgrade > ($marker)
    ") | save Dockerfile
    podman --storage-opt=additionalimagestore=/usr/lib/bootc/storage build --network=none -t $image .
    # The delta builder needs a complete image, including layers in the additional store.
    let target_archive = "/var/tmp/bootc-unified-delta-target.oci.tar"
    podman --storage-opt=additionalimagestore=/usr/lib/bootc/storage save --format oci-archive --output $target_archive $image
    let target = skopeo inspect $"oci-archive:($target_archive)" | from json
    assert ($target.Digest != $source.Digest)
    let upgrade_delta = "/var/tmp/image-2-to-3.oci-delta"
    oci-delta create $"oci-archive:($source_archive)" $"oci-archive:($target_archive)" $upgrade_delta
    podman rmi $image

    # A previous interrupted import can leave the target in composefs only.
    unshare --mount --propagation private sh -c 'mount -o remount,rw /sysroot && exec bootc internals cfs --repo /sysroot/composefs oci pull "$1"' sh $"oci-archive:($upgrade_delta)"
    let checked = bootc image cmd list --no-trunc --filter $"reference=($image)" --format json | from json | first
    assert equal $checked.Digest $source.Digest
    assert equal (bootc status --json | from json).status.staged null

    let expected = (open $state)
        | update digest $target.Digest
        | update source_id $source.Id
        | update marker "delta-unified-upgrade"
    $expected | to json | save --force $state
    unshare --net bootc upgrade --from-delta $upgrade_delta
    let staged = (bootc status --json | from json).status.staged.image
    assert equal $staged.image.image $image
    assert equal $staged.imageDigest $target.Digest
    verify_unified_storage $expected
    tmt-reboot
}

def main [] {
    match $env.TMT_REBOOT_COUNT? {
        null | "0" => initial_build,
        "1" => {
            verify_delta
            if (open $state).unified { upgrade_delta }
        },
        "2" => verify_delta,
        $o => { error make { msg: $"Invalid TMT_REBOOT_COUNT ($o)" } },
    }
}
