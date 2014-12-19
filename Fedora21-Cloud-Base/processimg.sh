#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free  Software Foundation; either version 2 of the License, or
# (at your option)  any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
#
# purpose: This script will download a fedora image and then modify it 
#          to prepare it for Digital Ocean's infrastructure. It uses 
#          Docker to hopefully guarantee the behavior is consistent across 
#          different machines.
#  author: Dusty Mabe (dusty@dustymabe.com)

set -eux 
mkdir -p /tmp/doimg/

docker run -i --rm --privileged -v /tmp/doimg:/tmp/doimg fedora:20 bash << 'EOF'
set -eux
WORKDIR=/tmp/tmp
TMPMNT=/tmp/tmp/mnt

# Vars for the image
XZIMGURL='http://download.fedoraproject.org/pub/fedora/linux/releases/21/Cloud/Images/x86_64/Fedora-Cloud-Base-20141203-21.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
IMG=${XZIMG:0:-3}           # Pull .xz off of the end

# URL/File location for upstream DO data source file.
DODATASOURCEURL='http://bazaar.launchpad.net/~cloud-init-dev/cloud-init/trunk/download/head:/datasourcedigitaloce-20141016153006-gm8n01q6la3stalt-1/DataSourceDigitalOcean.py'
export DODATASOURCEFILE='/usr/lib/python2.7/site-packages/cloudinit/sources/DataSourceDigitalOcean.py'

# File location for DO cloud config
export DOCLOUDCFGFILE='/etc/cloud/cloud.cfg.d/01_digitalocean.cfg'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
yum install -y gdisk wget e2fsprogs

# Get the xz image and decompress it
wget $XZIMGURL && unxz $XZIMG

# Convert to GPT
sgdisk -g -p $IMG

# Find the starting byte and the total bytes in the 1st partition
# NOTE: normally would be able to use partx/kpartx directly to loopmount
#       the disk image and add the partitions, but inside of docker I found
#       that wasn't working quite right so I resorted to this manual approach.
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Loopmount the first partition of the device
LOOPDEV=/dev/loop8
mknod -m660 /dev/loop8 b 7 8
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Add in DOROOT label to the root partition
e2label $LOOPDEV 'DOROOT'

# Mount it on $TMPMNT
mount $LOOPDEV $TMPMNT

# Get the DO datasource and store in the right place
# NOTE: curl doesn't work inside chroot so doing it here
curl $DODATASOURCEURL > ${TMPMNT}/${DODATASOURCEFILE}

# chroot into disk Image
chroot $TMPMNT

# Put in place the config from Digital Ocean
cat << END > $DOCLOUDCFGFILE
datasource_list: [ DigitalOcean, None ]
datasource:
 DigitalOcean:
   retries: 5
   timeout: 10
vendor_data:
   enabled: True
END

# restore selinux permissions (from inside chroot)
chcon system_u:object_r:etc_t:s0 $DOCLOUDCFGFILE
chcon system_u:object_r:lib_t:s0 $DODATASOURCEFILE

# Set selinux to permissive because some of DO's older infrastructure in
# some datacenters do things that make selinux complain. The newer datacenters
# support selinux and if the user wants selinux in those datacenters they
# can change this back to enforcing.
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Exit the chroot
exit

# umount and tear down loop device
umount $TMPMNT
losetup -d $LOOPDEV
rm $LOOPDEV

# finally, cp $IMG into /tmp/doimg/ on the host
cp -a $IMG /tmp/doimg/ 

EOF
