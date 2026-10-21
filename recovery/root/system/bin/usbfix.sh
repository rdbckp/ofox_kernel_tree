#!/system/bin/sh
# Jaga gadget tetap ke-bind: adbd restart (service.adb.root) bikin FFS close -> UDC ke-unbind.
# Tiap UDC kosong dan syarat siap, bind ulang lalu cmode 1 supaya musb kirim event connect.
G=/config/usb_gadget/g1
U=/sys/class/udc/musb-hdrc
L=/tmp/usbfix.log
echo "usbfix start" > $L
while true; do
  if [ "$(getprop sys.usb.config)" = "mtp,adb" ] && [ -e $G/configs/b.1/f1 ] && [ -e $G/configs/b.1/f2 ] && [ -e /dev/usb-ffs/adb/ep2 ]; then
    if [ -z "$(cat $G/UDC 2>/dev/null)" ]; then
      echo "$(date +%s) UDC kosong, bind ulang" >> $L
      echo musb-hdrc > $G/UDC 2>>$L
      sleep 1
      echo 1 > $U/device/cmode 2>>$L
      echo "$(date +%s) state=$(cat $U/state)" >> $L
    fi
  fi
  sleep 1
done
