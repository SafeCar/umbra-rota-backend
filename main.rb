require 'sinatra'
require 'faye/websocket'
require 'json'
require 'net/http'

#configure {set :server, :puma}
Faye::WebSocket.load_adapter('thin')

$data = nil
$sockets_seatbelt = []
$sockets_airbag_crash = []
$sockets_airbag = []
$sockets_location = []
$sockets_speed = []
$called = false

get '/auth_test' do
  {status: 'ok'}.to_json
end

get '/permission' do
  {status: 'ok',  permissions: [0, 1]}.to_json
end

get '/event' do
  ws = Faye::WebSocket.new(request.env)

  ws.on :open do |event|

  end

  ws.on :message do |event|
    #puts event.data
    data = JSON.parse(event.data)['filters']
    data.map do |filter|
      puts filter['name']
      case filter['name']
        when 'seatbelt'
          $sockets_seatbelt.push(ws)
        when 'inhibited'
          $sockets_airbag.push(ws)
        when 'location'
          $sockets_location.push({ws: ws, lat: filter['range'][0], lon: filter['range'][1]})
        when 'speed'
          $sockets_speed.push(ws)
        when 'crash'
          $sockets_airbag_crash.push(ws)
        else

      end
    end
  end

  ws.on :close do
    EM.next_tick do
      $sockets_seatbelt.delete(ws)
      $sockets_airbag.delete(ws)
      $sockets_airbag_crash.delete(ws)
      $sockets_speed.delete(ws)
      $sockets_location.delete_if do |x|
        x[:ws] == ws
      end
    end
  end

  ws.rack_response
end

Thread.new do
  signal_list = %w(DriverBeltFastened AirbagCrashInfoDetected PassengerAirbagInhibited InstantSpeed)
  while true
    begin
      $data = JSON.parse(Net::HTTP.get('area2.mobilecinq.com', '/ceasimulator4/getData.php', port = 8089))['records'].select do |signal|
        signal_list.include?(signal['signal']) || (signal['signal'] == 'GPS' && signal['signal2'] == 'Current')
      end

      # GPS

      # Crash
      if $data[1]['value'] == '1'
        unless $called
          $called = true
          Net::HTTP.start('ringer.azurewebsites.net', 80) {|http|
            http.post('/api/voice/',
                      '{"telephone":"+8618521598192","name":"Doctor James Marcus","pronoun":"him","VIN":"455K","lat":51.503262,"lon":-0.127701}',
                      initheader = {'Content-Type' => 'application/json'}) do |r|
            end
          }
        end

        $sockets_airbag_crash.each do |ws|
          EM.next_tick do
            ws.send({message: 'The driver has met a car crash'}.to_json)
            ws.rack_response
            $sockets_airbag_crash.delete(ws)
          end
        end
      end

      # Seat belt
      #puts $data[2].to_json
      if $data[2]['value'] == '0'
        #puts $sockets_seatbelt.to_json
        $sockets_seatbelt.each do |ws|
          EM.next_tick do
            ws.send({message: 'The driver is not driving with a seatbelt fastened'}.to_json)
            ws.rack_response
            $sockets_seatbelt.delete(ws)
          end
        end
      end

      # Speed
      if $data[4]['value'].to_i >= 120
        $sockets_speed.each do |ws|
          EM.next_tick do
            ws.send({message: 'The driver is overspeed'}.to_json)
            ws.rack_response
            $sockets_speed.delete(ws)
          end
        end
      end

      puts $data.to_json
      sleep 10
    rescue Exception => e
      puts e
    end
  end
end