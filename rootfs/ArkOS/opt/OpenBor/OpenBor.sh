#!/bin/bash
sudo systemctl start openborhotkey.service

if [[ "$1" == "OpenBor" ]]; then
    file="$2"
    basefile=$(basename -- "$file")
    basefilename=${basefile%.*}
    
    # Clean up old links
    rm -f "/opt/OpenBor/Paks/$basefile"
    ln -s "$2" "/opt/OpenBor/Paks/$basefile"
    
    # Copy config files
    if [ ! -f "/opt/OpenBor/Saves/${basefilename}.cfg" ]; then
        cp "/opt/OpenBor/Saves/master.cfg" "/opt/OpenBor/Saves/${basefilename}.cfg"
    fi
    
    cd /opt/OpenBor/ || exit 1
    LD_LIBRARY_PATH=. ./OpenBOR
    # Only delete the link files currently in use
    rm -f "/opt/OpenBor/Paks/$basefile"
else
    file="$2"
    basefile=$(basename -- "$file")
    basefilename=${basefile%.*}
    
    rm -f "/opt/OpenBorFF/Paks/$basefile"
    ln -s "$2" "/opt/OpenBorFF/Paks/$basefile"
    
    if [ ! -f "/opt/OpenBorFF/Saves/${basefilename}.cfg" ]; then
        cp "/opt/OpenBorFF/Saves/master.cfg" "/opt/OpenBorFF/Saves/${basefilename}.cfg"
    fi
    
    cd /opt/OpenBorFF/ || exit 1
    sdl_controllerconfig="190000004b4800000011000000010000,GO-Super Gamepad,x:b2,a:b1,b:b0,y:b3,back:b12,start:b13,dpleft:b10,dpdown:b9,dpright:b11,dpup:b8,leftshoulder:b4,lefttrigger:b6,rightshoulder:b5,righttrigger:b7,leftstick:b14,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,platform:Linux,"
  	SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig" ./OpenBOR
    rm -f "/opt/OpenBorFF/Paks/$basefile"
fi

sudo systemctl stop openborhotkey.service
# Fix: use > instead of >>
printf "\033c" > /dev/tty1