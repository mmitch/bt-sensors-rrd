#!/bin/bash

rrds=(~/rrd/bt-sensors-*.rrd)

colors=(f66 444 44f)

plot_it() {
    local value=$1 label=$2 format=$3
    local rrd

    local names=()
    for rrd in "${rrds[@]}"; do
	name=${rrd%.rrd}
	name=${name##*/bt-sensors-}
	names+=( "$name" )
    done
    
    local args=("bt-sensor.$value.png"
	  --start=-6h
	  --imgformat=PNG --width=1024 --height=640
	  --slope-mode --alt-autoscale
	  --title "$label"
	  --left-axis-format "$format" --units-length=8 --units-exponent=0)

    local data=() graph=()

    local i=0
    for name in "${names[@]}"; do
	data+=( "DEF:$name=${rrds[$((i++))]}:$value:AVERAGE" )
	data+=( "VDEF:${name}_min=$name,MINIMUM" )
	data+=( "VDEF:${name}_avg=$name,AVERAGE" )
	data+=( "VDEF:${name}_max=$name,MAXIMUM" )
    done

    local names_concat
    names_concat=$(IFS=, ; echo "${names[*]}")
    local minimum="CDEF:min=$names_concat"
    local maximum="CDEF:max=$names_concat"
    for (( i=1; i < ${#names[@]}; i++ )); do
	minimum="$minimum,MINNAN"
	maximum="$maximum,MAXNAN"
    done
    data+=( "$minimum" "$maximum" )
    data+=( "CDEF:delta=max,min,-" )
    graph+=( "LINE:min" "AREA:delta#eee:STACK" )
    
    i=0
    for name in "${names[@]}"; do
	color=${colors[$((i++))]}
	graph+=( "LINE:$name#$color:$name $label" )
	graph+=( "GPRINT:${name}_min:min\: $format" )
	graph+=( "GPRINT:${name}_avg:avg\: $format" )
	graph+=( "GPRINT:${name}_max:max\: $format\n" )
    done
    
    rrdtool graph "${args[@]}" "${data[@]}" "${graph[@]}"
}

plot_it temp_c   'temperature [°C]'        '%2.1lf °C'
plot_it hum_pc   'humidity [%]'            '%3.1lf %%'
plot_it batt_mv  'battery [mV]'            '%4.0lf mV'
plot_it batt_pc  'battery [%]'             '%3.1lf %%'
plot_it rssi     'signal strength [RSSI]'  '%3.1lf'
