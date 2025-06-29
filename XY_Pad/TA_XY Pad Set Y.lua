-- @noindex

local entrypath = ({reaper.get_action_context()})[2]:match('^.+[\\//]')
package.path = string.format('%s?.lua;', entrypath)

require('extstate').send_param('y')
