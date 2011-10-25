require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'couchrest'
require 'yaml'
require 'rack/csrf'
require 'holidays'
require 'holidays/de'

configure :production do
  set :db, "#{ENV['CLOUDANT_URL']}/recharge"
  use Rack::Csrf, :raise => true
end

configure :test do
  set :db, ENV['RECHARGE_TEST_DB'] || 'http://localhost:5984/recharge_test'
end

configure :cucumber do
  set :db, ENV['RECHARGE_TEST_DB'] || 'http://localhost:5984/recharge_test'
  use Rack::Csrf, :raise => true
end

configure :development do
  set :db, ENV['RECHARGE_DEV_DB'] || 'http://localhost:5984/recharge_development'
end

enable :sessions

set :views, './views'
set :public, File.dirname(__FILE__) + '/public'

class Date
  def to_s
    strftime('%Y%m%d')
  end
end

helpers do
  def db
    @db ||= CouchRest.database(settings.db)
  end

  def holidays_in(year, region)
    first_day = Date.ordinal(year, 1)
    last_day = Date.ordinal(year, -1)
    holidays = Holidays.between(first_day, last_day, region.to_sym).inject({}) do |result, holiday|
      result[holiday[:date].to_s] = holiday[:name]
      result
    end
  end

  def calendar_for(year, vacation, active_holidays)
    first = Date.ordinal(year, 1)
    last = Date.ordinal(year, -1)
    holidays = holidays_in(year, :de)
    cal = [%(<table border="0" cellspacing="0" cellpadding="0">)]
    cal << %(<tbody>)
    first.upto(last) do |date|
      if date.day == 1
        cal << %(<tr id="#{date.year}#{'%02d' % date.mon}">)
        cal << %(<th>#{month_name_for(date.mon)}</th>)
      end
      next if weekend?(date)
      css_classes = []
      css_classes << 'monday' if monday?(date)
      css_classes << 'friday' if friday?(date)
      css_classes << 'vacation' if vacation.include?(date.to_s)
      if holidays.has_key?("#{date}")
        css_classes << 'holiday'
        title = holidays["#{date}"]
      else
        title = ""
      end
      css_classes << 'active' << 'holiday' if active_holidays.include?(date.to_s)
      cal << %(<td id="#{date}" class="#{css_classes.join(' ')}" title="#{title}">#{date.day}</td>)
      cal << %(</tr>) if date.succ.month != date.month
    end
    cal << %(</tbody>)
    cal << %(</table>)
    cal.join("\n")
  end

  def monday?(time)
    time.wday == 1
  end

  def friday?(time)
    time.wday == 5
  end

  def weekend?(time)
    [0,6].include?(time.wday)
  end

  def id_for(*args)
    case args.size
    when 2 then "#{args[0]}#{"%02d" % args[1]}"
    else "#{args[0]}#{"%02d" % args[1]}#{"%02d" % args[2]}"
    end
  end

  def month_name_for(month)
    %w(Jan Feb Mär Apr Mai Jun Jul Aug Sep Okt Nov Dez)[month-1]
  end

  def button_label
    case request.fullpath
    when '/', %r(^/20[0-9]{2}$)
      "Kalender behalten"
    else
      "Kalender aktualisieren"
    end
  end

  def halt_on_empty_vacation
    halt 406, "Please mark anything as your vacation!" if !params[:vacation] ||
        params[:vacation].empty? || params[:vacation].values.all?{|v| v.empty?}
  end

  def csrf_token
    Rack::Csrf.csrf_token(env)
  end

  def clippy(text, bgcolor='#FFFFFF')
    html = <<-EOF
      <object classid="clsid:d27cdb6e-ae6d-11cf-96b8-444553540000"
              width="110"
              height="14"
              id="clippy" >
      <param name="movie" value="/clippy.swf"/>
      <param name="allowScriptAccess" value="always" />
      <param name="quality" value="high" />
      <param name="scale" value="noscale" />
      <param NAME="FlashVars" value="text=#{text}">
      <param name="bgcolor" value="#{bgcolor}">
      <embed src="/clippy.swf"
             width="110"
             height="14"
             name="clippy"
             quality="high"
             allowScriptAccess="always"
             type="application/x-shockwave-flash"
             pluginspage="http://www.macromedia.com/go/getflashplayer"
             FlashVars="text=#{text}"
             bgcolor="#{bgcolor}"
      />
      </object>
    EOF
  end

  def link_to_icalendar_export
    calendar_path = "/ics/#{params[:calendar]}"
    calendar_url = "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}#{calendar_path}"
    if request.fullpath =~ /^\/cal\//
      %Q!<div id="ics"><a href="#{calendar_path}" title="Mit dieser Adresse kann der Kalender abonniert werden">Kalenderadresse</a>#{clippy(calendar_url)}</div>!
    else
      '&nbsp;'
    end
  end

  def link_to_previous_year(year)
    previous_year = year - 1
    target_path = if request.path_info =~ %r(\/#{year}$)
      request.path_info.gsub(%r(\/#{year}$), "/#{previous_year}")
    else
      request.path_info + "/#{previous_year}"
    end.gsub(%r(//), '/')
    %Q(<a id="previous" class="btn primary" href="#{target_path}">← #{previous_year}</a>)
  end

  def link_to_next_year(year)
    next_year = year + 1
    target_path = if request.path_info =~ %r(\/#{year}$)
      request.path_info.gsub(%r(\/#{year}$), "/#{next_year}")
    else
      request.path_info + "/#{next_year}"
    end.gsub(%r(//), '/')
    %Q(<a id="next" class="btn primary" href="#{target_path}">#{next_year} →</a>)
  end

  def ranges_from(array)
    ranges = []
    left, right = array.first, nil
    array.each do |obj|
      if right && obj != right.succ
        ranges << Range.new(left,right)
        left = obj
      end
      right = obj
    end
    ranges << Range.new(left,right)
  end

  def show_cal(vacation, holidays, year)
    erb :index, :locals => {:vacation => vacation, :holidays => holidays, :year => year}
  end
end

get '/:year?' do
  expires 300, :public, :must_revalidate
  year = (params[:year] || Time.now.year).to_i
  first = Date.ordinal(year, 1)
  last = Date.ordinal(year, -1)
  show_cal([], Holidays.between(first, last, :de).map{|h| h[:date].to_s}, year)
end

post '/:year?' do
  halt_on_empty_vacation
  response = db.save_doc(:vacation => params[:vacation], :holidays => params[:holidays])
  content_type :json
  url = "/cal/#{response['id']}"
  url += "/#{params[:year]}" if params[:year]
  {:url => url}.to_json
end

get '/cal/:calendar/?:year?' do |cal, year|
  doc = db.get(cal)
  etag doc.rev
  year ||= Time.now.year.to_s
  first = Date.ordinal(year.to_i, 1)
  last = Date.ordinal(year.to_i, -1)
  show_cal(doc['vacation'][year] || [],
      doc['holidays'][year] || Holidays.between(first, last, :de).map{|h| h[:date].to_s}, year.to_i)
end

post '/cal/:calendar/?:year?' do
  halt_on_empty_vacation
  doc = db.get(params[:calendar])
  doc['vacation'].merge!(params[:vacation])
  doc['holidays'].merge!(params[:holidays])
  response = db.save_doc(doc)
  content_type :json
  url = "/cal/#{response['id']}"
  url += "/#{params[:year]}" if params[:year]
  {:url => url}.to_json
end

get '/ics/:calendar' do
  doc = db.get(params[:calendar])
  calendar = Icalendar::Calendar.new
  calendar.custom_property("X-WR-CALNAME", "Vacation")
  doc['vacation'].each_value do |by_year|
    ranges_from(by_year).each do |vacation|
      calendar.event do
        dtstart Date.parse(vacation.begin)
        dtend Date.parse(vacation.last).succ
        summary 'Vacation'
      end
    end
  end
  content_type :ics
  calendar.to_ical
end

get '/holidays/:region/:year' do |region, year|
  begin
    etag "#{region}-#{year}"
    content_type :json
    holidays_in(year.to_i, region).to_json
  rescue Holidays::UnknownRegionError
    not_found
  end
end