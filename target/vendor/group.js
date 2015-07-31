var Channel, Group, Message,
  __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; },
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

Message = require('./message');

Channel = require('./channel');

Group = (function(_super) {
  __extends(Group, _super);

  function Group() {
    this._onCreateChild = __bind(this._onCreateChild, this);
    this._onUnArchive = __bind(this._onUnArchive, this);
    this._onArchive = __bind(this._onArchive, this);
    this._onOpen = __bind(this._onOpen, this);
    this._onClose = __bind(this._onClose, this);
    return Group.__super__.constructor.apply(this, arguments);
  }

  Group.prototype.close = function() {
    var params;
    params = {
      "channel": this.id
    };
    return this._client._apiCall('groups.close', params, this._onClose);
  };

  Group.prototype._onClose = function(data) {
    return this._client.logger.debug(data);
  };

  Group.prototype.open = function() {
    var params;
    params = {
      "channel": this.id
    };
    return this._client._apiCall('groups.open', params, this._onOpen);
  };

  Group.prototype._onOpen = function(data) {
    return this._client.logger.debug(data);
  };

  Group.prototype.archive = function() {
    var params;
    params = {
      "channel": this.id
    };
    return this._client._apiCall('groups.archive', params, this._onArchive);
  };

  Group.prototype._onArchive = function(data) {
    return this._client.logger.debug(data);
  };

  Group.prototype.unarchive = function() {
    var params;
    params = {
      "channel": this.id
    };
    return this._client._apiCall('groups.unarchive', params, this._onUnArchive);
  };

  Group.prototype._onUnArchive = function(data) {
    return this._client.logger.debug(data);
  };

  Group.prototype.createChild = function() {
    var params;
    params = {
      "channel": this.id
    };
    return this._client._apiCall('groups.createChild', params, this._onCreateChild);
  };

  Group.prototype._onCreateChild = function(data) {
    return this._client.logger.debug(data);
  };

  return Group;

})(Channel);

module.exports = Group;
