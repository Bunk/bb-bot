# Description:
#   Hubot interface to octopus deploy
#
# Commands:
#   hubot promote <project> from <env1> to <env2> - Hubot promotes <project> on <env1> to <env2>
#   hubot deploy <project> version <version> to <env> - Hubot deploys the specified version of <project> to <env>
#   hubot deploy status - Hubot prints a dashboard of environments and currently deployed versions.
#
# Configuration:
#   HUBOT_OCTOPUS_URL_BASE: required
#   HUBOT_OCTOPUS_KEY: required
#
# Author:
#   JD Courtoy


_ = require('lodash')
q = require('q')
util = require('util')
semver = require('semver')
Table = require('cli-table')

apikey = process.env.HUBOT_OCTOPUS_KEY
urlBase = process.env.HUBOT_OCTOPUS_URL_BASE

module.exports = (robot) ->
  robot.respond /(deploy|delpoy) status$/i, (msg) ->
    getItems(robot, "api/dashboard")
      .then (data) ->
        m = "_We're currently rolling with_:"
        for proj in data.Projects
          if proj
            m = m + "\n\n *Project*: " + proj.Name
            projItems = _.filter(data.Items, (i) -> if i.ProjectId == proj.Id then i)

            if projItems && projItems.length > 0
              for item in projItems
                if item
                  enviro = _.find(data.Environments, (env) -> env.Id == item.EnvironmentId)
                  tabset = enviro.Name.length > "\t" ? " : \t" : " : \t\t"
                  formata = "\n  > %s\t\t : %s - %s"
                  formatb = "\n  > %s\t : %s - %s"
                  format = if enviro.Name.length >= 4 then formatb else formata
                  robot.logger.info format
                  m = m + util.format(format, enviro.Name, item.ReleaseVersion, item.State)
            else
              m = m + "\n  > No Deployments"
        msg.send m
      .catch (error) ->
        msg.send error

  robot.respond /(deploy|delpoy) status table$/i, (msg) ->
    getItems(robot, 'api/dashboard')
      .then (data) ->
        table = new Table
          head: ['_Project_', '_Env_', '_Version_', '_State_']
          colWidths: [20, 10, 12, 10]
        data.Projects.forEach (project) ->
          data.Environments.forEach (env, i) ->
            item = _.find(data.Items, (item) -> item.ProjectId == project.Id && item.EnvironmentId == env.Id)
            name = (project.Name if i == 0) || ''
            version = (item.ReleaseVersion if item) || ''
            state = (item.State if item) || ''
            row = [name, env.Name, version, state]
            table.push(row)

        table = table.toString().replace(/\t/g, '    ')
        msg.send "_We're currently rolling with_: \n\n#{table}"


  robot.respond /(promote) (.+) from (.+) to (.+)/i, (msg) ->
    projectName = msg.match[2]
    sourceEnvName = msg.match[3]
    targetEnvName = msg.match[4]

    getItem(robot, 'api/environments', findByName(sourceEnvName))
      .then (sourceEnv) ->
        if (!sourceEnv)
          throw new Error("Could not find environment #{sourceEnvName}")

        this.sourceEnv = sourceEnv
        getItem(robot, 'api/environments', findByName(targetEnvName))
      .then (targetEnv) ->
        if (!targetEnv)
          throw new Error("Could not find environment #{targetEnvName}")

        this.targetEnv = targetEnv
        getItems(robot, 'api/projects', filterByName(projectName))
      .then (projects) ->
        if (!projects && !projects.length)
          throw new Error("Could not find any projects starting with #{projectName}")

        promises = _.map projects.Items, (project) ->
          promoteRelease(robot, msg, project, this.sourceEnv, this.targetEnv)

        q.all promises
      .then (releases) ->
        releases.forEach (release) ->
          msg.send "Promoted *#{release.project.Name} (#{release.version}) from #{release.sourceEnv.Name} to #{release.targetEnv.Name}"
      .catch (error) ->
        msg.send error

  robot.respond /(deploy|delpoy) (.+) version (.+) to (.+)/i, (msg) ->
    projectName = msg.match[2]
    version = msg.match[3]
    targetEnvName = msg.match[4]

    getItem(robot, "api/projects", findByName(projectName))
      .then (project) ->
        if (!project)
          throw new Error("Could not find project #{projectName}");

        this.project = project
        getItem(robot, "api/environments", findByName(targetEnvName))
      .then (targetEnv) ->
        if (!targetEnv)
          throw new Error("Could not find environment #{targetEnvName}");

        this.targetEnv = targetEnv
        findRelease(robot, this.project, version)
      .then (release) ->
        if (!release)
          throw new Error("Could not find previous release");

        this.release = release
        deployRelease(robot, release, targetEnv)
      .then (deployment) ->
        msg.send "Deploying #{this.release.Version} to #{targetEnvName}"
      .catch (error) ->
        msg.send error

createHTTPCall = (robot, urlPath) ->
  robot.http("#{urlBase}/#{urlPath}")
       .header("X-Octopus-ApiKey", apikey)
       .header("content-type", "application/json")

deployRelease = (robot, release, environment) ->
  deferred = q.defer()
  deployment =
    Comments: "Deployed from Hubot"
    EnvironmentId: environment.Id
    ReleaseId: release.Id

  createHTTPCall(robot, "/api/deployments")
  .post(JSON.stringify(deployment)) (err, res, body) ->
    if(err)
      deferred.reject err
    else
      deferred.resolve (JSON.parse body)
  deferred.promise

promoteRelease = (robot, msg, project, sourceEnv, targetEnv) ->
  mostRecentReleaseByEnv(robot, project, sourceEnv)
    .then (sourceRelease) ->
      if (!sourceRelease)
        throw new Error("Could not find previous release from #{sourceEnv.Name}");

      robot.logger.info "#{project.Name} [#{sourceEnv.Name}] : v#{sourceRelease.Version}"

      this.sourceRelease = sourceRelease
      deployRelease(robot, sourceRelease, targetEnv)
    .then (deployment) ->
      promotion =
        deployment: deployment
        project: project
        sourceEnv: sourceEnv
        targetEnv: targetEnv
        version: this.sourceRelease.Version

getItems = (robot, urlPath) ->
  deferred = q.defer()
  createHTTPCall(robot,urlPath)
  .get() (err, res, body) ->
    if err
      deferred.reject(err)
    else
      items = (JSON.parse body)
      deferred.resolve(items)
  deferred.promise

getItem = (robot, urlPath, selectFunc) ->
  deferred = q.defer()
  createHTTPCall(robot, urlPath)
  .get() (err, res, body) ->
    if err
      deferred.reject(err)
    else
      items = (JSON.parse body).Items
      deferred.resolve(selectFunc(items))
  deferred.promise

findByName = (name)->
  (items) ->_.find(items, (item) -> item.Name == name)

filterByName = (name) ->
  (items) -> _.filter(items, (item) -> _.startsWith(item.Name.toLowerCase(), name.toLowerCase()))

findByFirst = () ->
  (items) -> _.first(items)

findByVersion = (version) ->
  (items) -> _.find(items, (item)-> item.Version == version)

findByEnvironment = (environment) ->
  (items) -> _.find(items, (item) -> item.EnvironmentId == environment.Id)

findRelease = (robot, project, version) ->
  releasesUrl = project.Links["Releases"].replace /{.*}/,""
  getItem(robot, releasesUrl, findByVersion(version))

mostRecentDeployment = (robot, project, environment) ->
  getItem(robot, 'api/dashboard/dynamic', (items) ->
    filtered = _.filter(items, (item) -> item.EnvironmentId == environment.Id && item.ProjectId == project.Id)
    filtered.sort(semver.rcompare)
    _.first(filtered))

mostRecentRelease = (robot, project) ->
  releasesUrl = project.Links["Releases"].replace /{.*}/, ""
  getItem(robot, releasesUrl, findByFirst())
  .then (val) -> val

mostRecentReleaseByEnv = (robot, project, env) ->
  mostRecentDeployment(robot, project, env)
    .then (deployment) -> findRelease(robot, project, deployment.ReleaseVersion)
