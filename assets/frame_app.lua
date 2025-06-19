local data = require('data.min')
local battery = require('battery.min')
local camera = require('camera.min')
local code = require('code.min')
local imu = require('imu.min')
local plain_text = require('plain_text.min')

-- Data Parsers Camera
data.parsers[CAPTURE_SETTINGS_MSG] = camera.parse_capture_settings
data.parsers[AUTO_EXP_SETTINGS_MSG] = camera.parse_auto_exp_settings
data.parsers[MANUAL_EXP_SETTINGS_MSG] = camera.parse_manual_exp_settings
data.parsers[TEXT_MSG] = plain_text.parse_plain_text
data.parsers[TAP_SUBS_MSG] = code.parse_code

-- Phone to Frame flags for camera
CAPTURE_SETTINGS_MSG = 0x0d
AUTO_EXP_SETTINGS_MSG = 0x0e
MANUAL_EXP_SETTINGS_MSG = 0x0f
TEXT_MSG = 0x0a
TAP_SUBS_MSG = 0x10

-- Data Parsers IMU
data.parsers[START_IMU_MSG] = code.parse_code
data.parsers[STOP_IMU_MSG] = code.parse_code

--Phone to frame flags for IMU
START_IMU_MSG = 0x40
STOP_IMU_MSG = 0x41

-- Frame to Phone flags
TAP_MSG = 0x09
IMU_DATA_MSG = 0x0A

function handle_tap()
	rc, err = pcall(frame.bluetooth.send, string.char(TAP_MSG))

	if rc == false then
		-- send the error back on the stdout stream
		print(err)
	end

end

-- draw the current text on the display
function print_text()
    local i = 0
    for line in data.app_data[TEXT_MSG].string:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end
end

function clear_display()
    frame.display.text(" ", 1, 1)
    frame.display.show()
    frame.sleep(0.04)
end

-- Main app loop
function app_loop()
	clear_display()
    local last_batt_update = 0
	local streaming = false
	local stream_rate = 1

	while true do
        rc, err = pcall(
            function()
				-- process any raw data items, if ready (parse into take_photo, then clear data.app_data_block)
				local items_ready = data.process_raw_items()

				if items_ready > 0 then
                    -- Camera Subscriber
					if (data.app_data[AUTO_EXP_SETTINGS_MSG] ~= nil) then
						rc, err = pcall(camera.set_auto_exp_settings, data.app_data[AUTO_EXP_SETTINGS_MSG])

						if rc == false then
							print(err)
						end

						data.app_data[AUTO_EXP_SETTINGS_MSG] = nil
					end

					if (data.app_data[MANUAL_EXP_SETTINGS_MSG] ~= nil) then
						rc, err = pcall(camera.set_manual_exp_settings, data.app_data[MANUAL_EXP_SETTINGS_MSG])

						if rc == false then
							print(err)
						end

						data.app_data[MANUAL_EXP_SETTINGS_MSG] = nil
					end

					if (data.app_data[TEXT_MSG] ~= nil and data.app_data[TEXT_MSG].string ~= nil) then
						print_text()
						frame.display.show()
						data.app_data[TEXT_MSG] = nil
					end
                     -- Tap Subscriber
					if (data.app_data[TAP_SUBS_MSG] ~= nil) then

						if data.app_data[TAP_SUBS_MSG].value == 1 then
							-- start subscription to tap events
							print('subscribing for taps')
							frame.imu.tap_callback(handle_tap)
						else
							-- cancel subscription to tap events
							print('cancel subscription for taps')
							frame.imu.tap_callback(nil)
						end

						data.app_data[TAP_SUBS_MSG] = nil
					end
                     -- Motion Subscriber
                	if (data.app_data[START_IMU_MSG] ~= nil) then
                        streaming = true
                			local rate = data.app_data[START_IMU_MSG].value
                			if rate > 0 then
                                stream_rate = 1 / rate
                			end
               				data.app_data[START_IMU_MSG] = nil
               		end
               		if (data.app_data[STOP_IMU_MSG] ~= nil) then
                        streaming = false
                		data.app_data[STOP_IMU_MSG] = nil
                	end
				end

				-- periodic battery level updates, 120s for a camera app
				last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 120)
				if camera.is_auto_exp then
					camera.run_auto_exposure()
				end
		         if streaming then
			       frame.sleep(stream_rate)
	    	    else
		         	frame.sleep(0.25)
		         --Cut sleeping rate in half because fuck it!
	    	    end
            end
		)
		-- Catch the break signal here and clean up the display
		if rc == false then
			-- send the error back on the stdout stream
			print(err)
			frame.display.text(" ", 1, 1)
			frame.display.show()
			frame.sleep(0.04)
			break
		end
	end
end

-- run the main app loop
app_loop()