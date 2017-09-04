# mpathtest -  test program for multipath, kpartx & udev #

This is a test program for the stability of dm-multipath devices. The
intention is to test the interaction of the kernel (storage devices and
dm-multipath), multipathd, kpartx, udev, systemd, and the related udev rules
under typical system set-up and failover scenarios.

The program needs at least one unused multipath device on the system it's
running on. The devices are specified by using the device mapper names as
command line arguments. If no no devices are given, it will grab all unused
multipath devices (devices with an open count of 0) it finds. For devices
given on the command line, existing unused kpartx partitions will be removed.

> **CAUTION: data on the devices used for testing will be destroyed!! **

The program will then set up a storage stack on top of the multipath LUNs as
specified on the command line, and run one or more tests. It will carry out
various sanity checks both after the initial setup and during/between tests,
checking whether

 * symlinks under `/dev` are created correctly,
 * symlinks are preserved in failover scenarios, even if 0 paths are left,
 * storage stacks such as partitions and LVM are set up correctly on top of
   the device, 
 * file systems are created and auto-mounted as expected, and preserved during
   failover scenarios as desired.

Care has been taken to make sure that the program cleans up after
running.

Apart from the testing itself, the program offers a variety of options to
control the debug levels of various programs during the test, in order to
debug problems or just learn about the interactions of the various programs.

Detailed description tbd.
