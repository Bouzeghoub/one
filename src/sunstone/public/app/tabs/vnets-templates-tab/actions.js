/* -------------------------------------------------------------------------- */
/* Copyright 2002-2018, OpenNebula Project, OpenNebula Systems                */
/*                                                                            */
/* Licensed under the Apache License, Version 2.0 (the "License"); you may    */
/* not use this file except in compliance with the License. You may obtain    */
/* a copy of the License at                                                   */
/*                                                                            */
/* http://www.apache.org/licenses/LICENSE-2.0                                 */
/*                                                                            */
/* Unless required by applicable law or agreed to in writing, software        */
/* distributed under the License is distributed on an "AS IS" BASIS,          */
/* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   */
/* See the License for the specific language governing permissions and        */
/* limitations under the License.                                             */
/* -------------------------------------------------------------------------- */

define(function(require) {
  var Sunstone = require('sunstone');
  var Notifier = require('utils/notifier');
  var Locale = require('utils/locale');
  var DataTable = require('./datatable');
  var OpenNebulaResource = require('opennebula/vntemplate');
  var OpenNebulaCluster = require('opennebula/cluster');
  var OpenNebulaAction = require('opennebula/action');
  var CommonActions = require('utils/common-actions');

  var RESOURCE = "VNTemplate";
  var XML_ROOT = "VNTEMPLATE";
  var TAB_ID = require('./tabId');
  var CREATE_DIALOG_ID = require('./form-panels/create/formPanelId');
  var ADD_AR_DIALOG_ID = require('tabs/vnets-tab/dialogs/add-ar/dialogId');
  var UPDATE_AR_DIALOG_ID = require('tabs/vnets-tab/dialogs/update-ar/dialogId');
  var RESERVE_DIALOG_ID = require('tabs/vnets-tab/dialogs/reserve/dialogId');
  var CLUSTERS_DIALOG_ID = require('utils/dialogs/clusters/dialogId');

  var _commonActions = new CommonActions(OpenNebulaResource, RESOURCE, TAB_ID,
    XML_ROOT, Locale.tr("Virtual Network Template created"));

  var _actions = {
    "VNTemplate.create" : _commonActions.create(CREATE_DIALOG_ID),
    "VNTemplate.create_dialog" : _commonActions.showCreate(CREATE_DIALOG_ID),
    "VNTemplate.list" : _commonActions.list(),
    "VNTemplate.show" : _commonActions.show(),
    "VNTemplate.refresh" : _commonActions.refresh(),
    "VNTemplate.delete" : _commonActions.del(),
    "VNTemplate.hold": _commonActions.singleAction('hold'),
    "VNTemplate.release": _commonActions.singleAction('release'),
    "VNTemplate.chown": _commonActions.multipleAction('chown'),
    "VNTemplate.chgrp": _commonActions.multipleAction('chgrp'),
    "VNTemplate.chmod": _commonActions.singleAction('chmod'),
    "VNTemplate.rename": _commonActions.singleAction('rename'),
    "VNTemplate.update" : _commonActions.update(),
    "VNTemplate.update_template" : _commonActions.updateTemplate(),
    "VNTemplate.append_template" : _commonActions.appendTemplate(),
    "VNTemplate.update_dialog" : _commonActions.checkAndShowUpdate(),
    "VNTemplate.show_to_update" : _commonActions.showUpdate(CREATE_DIALOG_ID),
    "VNTemplate.lockM": _commonActions.multipleAction('lock', false),
    "VNTemplate.lockU": _commonActions.multipleAction('lock', false),
    "VNTemplate.lockA": _commonActions.multipleAction('lock', false),
    "VNTemplate.unlock": _commonActions.multipleAction('unlock', false),
    "VNTemplate.add_ar" : {
      type: "single",
      call: OpenNebulaResource.add_ar,
      callback: function(req) {
        // Reset the wizard
        Sunstone.getDialog(ADD_AR_DIALOG_ID).hide();
        Sunstone.getDialog(ADD_AR_DIALOG_ID).reset();

        Sunstone.runAction("VNTemplate.show",req.request.data[0]);
      },
      error: Notifier.onError
    },

    "VNTemplate.rm_ar" : {
      type: "single",
      call: OpenNebulaResource.rm_ar,
      callback: function(req) {
        OpenNebulaAction.clear_cache("VNET");
        Sunstone.runAction("VNTemplate.show",req.request.data[0]);
      },
      error: Notifier.onError
    },

    "VNTemplate.update_ar" : {
      type: "single",
      call: OpenNebulaResource.update_ar,
      callback: function(req) {
        // Reset the wizard
        Sunstone.getDialog(UPDATE_AR_DIALOG_ID).hide();
        Sunstone.getDialog(UPDATE_AR_DIALOG_ID).reset();

        Sunstone.runAction("VNTemplate.show",req.request.data[0]);
      },
      error: Notifier.onError
    },

    "VNTemplate.reserve_dialog" : {
      type: "custom",
      call: function() {
        var selected_nodes = Sunstone.getDataTable(TAB_ID).elements();
        if (selected_nodes.length != 1) {
          Notifier.notifyMessage("Please select one (and just one) Virtual Network Template.");
          return false;
        }

        var resource_id = "" + selected_nodes[0];

        Sunstone.getDialog(RESERVE_DIALOG_ID).setParams({vnetId: resource_id});
        Sunstone.getDialog(RESERVE_DIALOG_ID).reset();
        Sunstone.getDialog(RESERVE_DIALOG_ID).show();
      }
    },

    "VNTemplate.addtocluster" : _commonActions.checkAndShow("clusters"),

    "VNTemplate.clusters" : {
      type: "single",
      call: OpenNebulaResource.show,
      callback: function(request, response) {
        Sunstone.getDialog(CLUSTERS_DIALOG_ID).setParams({
          element: response[XML_ROOT],
          resource:"vntemplate"
        });

        Sunstone.getDialog(CLUSTERS_DIALOG_ID).reset();
        Sunstone.getDialog(CLUSTERS_DIALOG_ID).show();
      },
      error: Notifier.onError
    }
  };

  return _actions;
});