Setup script (un-Tested) for a custom smart speaker using Raspberry Pi Zero W2 with a KEYSTUDIO ReSpeaker 2-Mic Pi HAT. 
The speaker will need to be connected to the speaker connector and not the headphone jack. (it is unknown if it will work on the jack with this config)
This Configuration uses the wyoming satellite protocal to work with home assistant. 
This should carry the hostname as the device name used in the configuration.
This config uses the hey_jarvis wake word and has the LED's enabled to indicate the wake word detection. 


Prerequisite
-Use Raspberry Pi Imager to load Rasberry Pi OS Lite (64bit) (2024-11-19 used at time of this writing)
-Edit setting to setup your Hostname, Username, and WiFi
  -To ensure I don't forget usernames I typically use the same as the Hostname. 
