# Description
#   A Hubot script for creating memes from templates using memegen.link.
#
# Configuration:
#   None
#
# Commands:
#   hubot meme list - Returns available meme templates from Memegen.link and their respective URLs (keys)
#   hubot meme <template> top: <text> bottom: <text> - Creates a <template> meme using <text> and returns links to it
#
# Notes:
#   None
#
# Author:
#   JD Courtoy

MEMEGEN_API_URL = "http://memegen.link"

module.exports = (robot) ->
    _templateCache = null

    robot.respond /meme list/i, (res) ->
      return res.send(_templateCache) if _templateCache?
      _queryApi res, "/templates/", (data) ->
        _templateCache = ""
        for template, url of data
          key = url.split "/"
          key = key[key.length - 1]
          _templateCache += "#{template} | Key: #{key} | Example: http://memegen.link/#{key}/hello/world.jpg\n"
        res.send _templateCache

    robot.respond /meme (\w+) top: (.+) bottom: (.+)/i, (res) ->
      template = res.match[1]
      topText = _sanitize(res.match[2])
      bottomText = _sanitize(res.match[3])

      _queryApi res, "/#{template}/#{topText}/#{bottomText}", (data) ->
        res.send "#{data.direct.visible}"

    robot.error (err, res) ->
      robot.logger.error "hubot-memegen: (#{err})"
      if (res?)
        res.reply "DOES NOT COMPUTE"

_sanitize = (str) ->
  str = str.replace(/\s+/g, '-')
  str = str.replace(/"/g, '')
  str = str.replace(/\?/g, '~q')
  str.toLowerCase()

_queryApi = (msg, parts, handler) ->
  robot.http("#{MEMEGEN_API_URL}#{parts}")
    .get() (err, res, body) ->
      robot.logger.info "#{MEMEGEN_API_URL}#{parts} #{body}"
      if err
        robot.emit 'error', err

      if res.statusCode isnt 200 and res.statusCode isnt 302
        msg.reply "The memegen API appears to be down, or I haven't been taught how to talk to it.  Try again later, please."
        robot.logger.error "hubot-memegen: #{body} (#{err})"
        return

      handler JSON.parse(body)
