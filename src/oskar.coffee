# polyfill for isArray method
typeIsArray = Array.isArray || ( value ) -> return {}.toString.call( value ) is '[object Array]'

express          = require 'express'
MongoClient      = require './modules/mongoClient'
SlackClient      = require './modules/slackClient'
routes           = require './modules/routes'
TimeHelper       = require './helper/timeHelper'
InputHelper      = require './helper/inputHelper'
OnboardingHelper = require './helper/onboardingHelper'
OskarTexts       = require './content/oskarTexts'
config           = require 'config'

class Oskar

  constructor: (mongo, slack, onboardingHelper) ->

    # set up app, mongo and slack
    @app = express()
    @app.set 'view engine', 'ejs'
    @app.set 'views', 'src/views/'
    @app.use '/public', express.static(__dirname + '/public')

    @mongo = mongo || new MongoClient()
    @mongo.connect()

    @slack = slack || new SlackClient()
    @slack.connect().then () =>
      @onboardingHelper.loadOnboardingStatusForUsers @slack.getUserIds()

    @onboardingHelper = onboardingHelper || new OnboardingHelper @mongo

    @setupRoutes()

    # dev environment shouldnt listen to slack events or run the interval
    if process.env.NODE_ENV is 'development'
      return

    @setupEvents()

    # check for user's status every hour
    setInterval =>
      @checkUpcomingEvents (@slack)
    , 1000 * 5 #* 60

  setupEvents: () =>
    @slack.on 'presence', @presenceHandler
    @slack.on 'message', @messageHandler
    @onboardingHelper.on 'message', @onboardingHandler

  setupRoutes: () ->

    routes(@app, @mongo, @slack)

    @app.set 'port', process.env.PORT || 5000
    @app.listen @app.get('port'), ->
      console.log "Node app is running on port 5000"

  presenceHandler: (data) =>

    # return if user has been disabled
    user = @slack.getUser data.userId
    if user is null
      return false

    # every hour, disable possibility to comment
    if data.status is 'triggered'
      @slack.disallowUserFeedbackMessage data.userId

    # if presence is not active, return
    if (user and user.presence isnt 'active')
      return

    # if a user exists, create, otherwise go ahead without
    @mongo.userExists(data.userId).then (res) =>
      if !res
        @mongo.saveUser(user).then (res) =>
          @requestUserFeedback data.userId, data.status
      else
        @requestUserFeedback data.userId, data.status

  messageHandler: (message) =>

    console.log message.text

    # if user is not onboarded, run until onboarded
    #if !@onboardingHelper.isOnboarded(message.user)
      #return @onboardingHelper.advance(message.user, message.text)

    if InputHelper.isCreateEvent(message.text)
      return @createEvent message.text, message.user

    if InputHelper.isYesStatus(message.text)
      return @attendEvent true, message.user

    if InputHelper.isNoStatus(message.text)
      return @attendEvent false, message.user

    # if user is asking for feedback of user with ID
    if userId = InputHelper.isAskingForUserStatus(message.text)
      return @revealStatus userId, message

    # if comment is allowed, save in DB
    #if @slack.isUserFeedbackMessageAllowed message.user
      #return @handleFeedbackMessage message

    # if user is asking for help, send a link to the FAQ
    if InputHelper.isAskingForHelp(message.text)
      return @composeMessage message.user, 'faq'

    if InputHelper.isAskingForAttendance(message.text)
      return @getAttendance message.user

    # if feedback is long enough ago, evaluate
    #@mongo.getLatestUserTimestampForProperty('feedback', message.user).then (timestamp) =>
      #@evaluateFeedback message, timestamp

  # is called from onboarding helper to compose messages
  onboardingHandler: (message) =>
    @composeMessage(message.userId, message.type)

  requestUserFeedback: (userId, status) ->

    if !@onboardingHelper.isOnboarded(userId)
      return @onboardingHelper.welcome(userId)

    @mongo.saveUserStatus userId, status

    console.log userId + status

    # if user switched to anything but active or triggered, skip
    if status != 'active' && status != 'triggered'
      return

    # if it's weekend or between 0-8 at night, skip
    user = @slack.getUser userId
    date = TimeHelper.getLocalDate(null, user.tz_offset / 3600)
    if (TimeHelper.isWeekend() || TimeHelper.isDateInsideInterval 0, 8, date || TimeHelper.isDateInsideInterval 17, 24, date)
      return

    @mongo.getLatestUserTimestampForProperty('feedback', userId).then (timestamp) =>

      # if user doesnt exist, skip
      if timestamp is false
        return

      # if timestamp has expired and user has not already been asked two times, ask for status
      today = new Date()
      @mongo.getUserFeedbackCount(userId, today).then (count) =>

        if (count < 2 && TimeHelper.hasTimestampExpired 6, timestamp)
          requestsCount = @slack.getfeedbackRequestsCount(userId)
          @slack.setfeedbackRequestsCount(userId, requestsCount + 1)
          @composeMessage userId, 'requestFeedback', requestsCount

  evaluateFeedback: (message, latestFeedbackTimestamp, firstFeedback = false) ->

    # if user has already submitted feedback in the last x hours, reject
    if (latestFeedbackTimestamp && !TimeHelper.hasTimestampExpired 4, latestFeedbackTimestamp)
      return @composeMessage message.user, 'alreadySubmitted'

    # check if user has send status and feedback in one message
    obj = InputHelper.isStatusAndFeedback message.text
    if obj isnt false
      @mongo.saveUserFeedback message.user, obj.status
      @handleFeedbackMessage({user: message.user , text: obj.message})
      @slack.setfeedbackRequestsCount(message.user, 0)
      return

    # if user didn't send valid feedback
    if !InputHelper.isValidStatus message.text
      return @composeMessage message.user, 'invalidInput'

    # if feedback valid, save and set count to 0
    @mongo.saveUserFeedback message.user, message.text
    @slack.setfeedbackRequestsCount(message.user, 0)

    @slack.allowUserFeedbackMessage message.user

    # get user feedback
    if (parseInt(message.text) < 3)
      return @composeMessage message.user, 'lowFeedback'

    if (parseInt(message.text) is 3)
      return @composeMessage message.user, 'averageFeedback'

    if (parseInt(message.text) > 3)
      return @composeMessage message.user, 'highFeedback'

    @composeMessage message.user, 'feedbackReceived'

  revealStatus: (userId, message) =>

    # distinguish between channel and user
    if userId is 'channel'
      @revealStatusForChannel(message.user)
    else
      @revealStatusForUser(message.user, userId)

  revealStatusForChannel: (userId) =>
    console.log "REVEAL STATUS OF CHANNEL FOR USER:", userId
    userIds = @slack.getUserIds()
    @mongo.getAllUserFeedback(userIds).then (res) =>
      @composeMessage userId, 'revealChannelStatus', res

  revealStatusForUser: (userId, targetUserId) =>
    userObj = @slack.getUser targetUserId

    # return if user has been disabled or is not available
    if userObj is null
      return

    @mongo.getLatestUserFeedback(targetUserId).then (res) =>
      if res is null
        res = {}
      res.user = userObj
      @composeMessage userId, 'revealUserStatus', res

  handleFeedbackMessage: (message) =>

    # after receiving it, save and disallow comments
    @slack.disallowUserFeedbackMessage message.user
    @mongo.saveUserFeedbackMessage message.user, message.text
    @composeMessage message.user, 'feedbackMessageReceived'

    # send feedback to everyone
    @mongo.getLatestUserFeedback(message.user).then (res) =>
      @broadcastUserStatus message.user, res.status, message.text

  broadcastUserStatus: (userId, status, feedback) ->

    user = @slack.getUser userId

    # compose user details
    user.profile = user.profile || {}
    userStatus =
      name       : user.profile.first_name || user.name
      status     : status
      feedback   : feedback

    # send update to all users
    if (channelId = process.env.CHANNEL_ID)
      return @composeMessage userId, 'newUserFeedbackToChannel', userStatus

    userIds = @slack.getUserIds()
    userIds.forEach (user) =>
      if (user isnt userId)
        @composeMessage user, 'newUserFeedbackToUser', userStatus

  composeMessage: (userId, messageType, obj) ->

    # introduction
    if messageType is 'introduction'
      userObj = @slack.getUser userId
      name = userObj.profile.first_name || userObj.name
      statusMsg = OskarTexts.introduction.format name

    # request feedback
    else if messageType is 'requestFeedback'
      userObj = @slack.getUser userId
      if obj < 1
        random = Math.floor(Math.random() * OskarTexts.requestFeedback.random.length)
        name = userObj.profile.first_name || userObj.name
        statusMsg = OskarTexts.requestFeedback.random[random].format name
        statusMsg += OskarTexts.requestFeedback.selection
      else
        statusMsg = OskarTexts.requestFeedback.options[obj-1]

    # channel info
    else if messageType is 'revealChannelStatus'
      statusMsg = ""
      obj.forEach (user) =>
        userObj = @slack.getUser user.id
        name = userObj.profile.first_name || userObj.name
        if !user.feedback
          statusMsg += OskarTexts.revealChannelStatus.error.format name

        else
          statusMsg += OskarTexts.revealChannelStatus.status.format name, user.feedback.status
          if user.feedback.message
            statusMsg += OskarTexts.revealChannelStatus.message.format user.feedback.message
        statusMsg += "\r\n"

    # user info
    else if messageType is 'revealUserStatus'
      name = obj.user.profile.first_name || obj.user.name
      if !obj.status
        statusMsg = OskarTexts.revealUserStatus.error.format name
      else
        statusMsg = OskarTexts.revealUserStatus.status.format name, obj.status
        if obj.message
          statusMsg += OskarTexts.revealUserStatus.message.format obj.message

    else if messageType is 'newUserFeedbackToChannel'
      statusMsg = OskarTexts.newUserFeedback.format obj.name, obj.status, obj.feedback
      return @slack.postMessageToChannel process.env.CHANNEL_ID, statusMsg

    else if messageType is 'newUserFeedbackToUser'
      statusMsg = OskarTexts.newUserFeedback.format obj.name, obj.status, obj.feedback
      return @slack.postMessage userId, statusMsg

    # faq
    else if messageType is 'faq'
      statusMsg = OskarTexts.faq

    else if messageType is 'eventCreated'
      user = @slack.getUser userId
      statusMsg = OskarTexts.eventCreated
      @slack.postMessageToChannel process.env.CHANNEL_ID || config.get('slack.channelId'), OskarTexts.eventCreatedChannel.format user.name, obj.name, obj.date

    else if messageType is 'eventAttendance'
      yeses = obj.attendance.filter (att) ->
        return att.response
      statusMsg = OskarTexts.eventAttendance.format yeses.length, obj.name, obj.startDate
      return @slack.postMessage userId, statusMsg

    else if messageType is 'eventAttended'
      statusMsg = OskarTexts.eventAttended.format obj.name, obj.startDate
      return @slack.postMessage userId, statusMsg

    else if messageType is 'eventNotAttended'
      statusMsg = OskarTexts.eventNotAttended.format obj.name
      return @slack.postMessage userId, statusMsg

    else if messageType is 'noEvent'
      statusMsg = OskarTexts.noEvent
      return @slack.postMessage userId, statusMsg

    else if messageType is 'upcomingEvent'
      statusMsg = OskarTexts.upcomingEvent.format obj.name, obj.startDate
      return @slack.postMessage userId, statusMsg

    # everything else, if array choose random string
    else
      if typeIsArray OskarTexts[messageType]
        random = Math.floor(Math.random() * OskarTexts[messageType].length)
        statusMsg = OskarTexts[messageType][random]
      else
        statusMsg = OskarTexts[messageType]

    if userId && statusMsg
      @slack.postMessage(userId, statusMsg)

  # interval to request feedback every hour
  checkUpcomingEvents: (slack) ->
    DAY = 24 * 60 * 60 * 1000;

    @mongo.getNextEvents().then (events) =>
      if events.length > 0
        event_time = new Date(events[0].startDate).getTime()
        now = new Date().getTime()
 
        if (event_time - DAY) < now && events[0].notificationSent == undefined
          @notifyUsersOfEvent(slack, events[0])
        
  notifyUsersOfEvent: (slack , event) ->
    @mongo.updateEventNotification event.name
    userIds = slack.getUserIds()
    userIds.forEach (userId) =>
      @composeMessage userId, 'upcomingEvent', event  

  createEvent: (text, user) ->
    array = text.split('\n')
    dateArray = array[2].split(' ')
    dateParts = dateArray[0].split('/')
    timeParts = dateArray[1].split(':')
    date = new Date(dateParts[2], dateParts[1]-1, dateParts[0], timeParts[0], timeParts[1])

    event =
        name : array[1]
        date : date
        recur : array[3]
    @mongo.saveEvent(event)
    @composeMessage user, 'eventCreated', event

  getAttendance: (user) ->
    events = []
    @mongo.getEvents().then (events) =>
      if(events.length > 0)
        @composeMessage user, 'eventAttendance', events[0]
      else
        @composeMessage user, 'noEvent'

  attendEvent: (attend, user) ->
    events = []
    @mongo.getEvents().then (events) =>
      if(events.length > 0)
        @mongo.saveEventAttendance(user, events[0], attend).then () =>
          if(attend)
            @composeMessage user, 'eventAttended', events[0]
          else
            @composeMessage user, 'eventNotAttended', events[0]
      else
        @composeMessage user, 'noEvent'

module.exports = Oskar
