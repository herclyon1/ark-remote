#!/bin/zsh
# Builds replay-dumper.dex next to this script from ReplayDumper.java (JDK: Android Studio's bundled JBR; SDK: android.jar + d8).
set -e
here=${0:A:h}
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
jbr=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
plat=$(ls -d $sdk/platforms/android-* | sort -V | tail -1)
bt=$(ls -d $sdk/build-tools/* | sort -V | tail -1)
tmp=$(mktemp -d)
"$jbr/bin/javac" --release 11 -cp "$plat/android.jar" -d $tmp/classes $here/ReplayDumper.java
JAVA_HOME="$jbr" "$bt/d8" --min-api 30 --output $tmp $tmp/classes/ReplayDumper.class
mv $tmp/classes.dex $here/replay-dumper.dex
rm -rf $tmp
echo "$here/replay-dumper.dex"
