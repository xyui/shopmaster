<?php
// $Id$

/**
 * Return an array of the modules to be enabled when this profile is installed.
 *
 * @return
 *  An array of modules to be enabled.
 */
function shopmaster_profile_modules() {
  return array(
    /* core */ 'block', 'color', 'filter', 'help', 'menu', 'node', 'system', 'user',
    /* aegir contrib */ 'hosting', 'hosting_task', 'hosting_client', 'hosting_package', 'hosting_server', 'hosting_queue_runner',
    'install_profile_api' /* needs >= 2.1 */, 'jquery_ui', 'modalframe', 'admin_menu',

    /* DEVUDO */
    'shop_hosting',

    /* Features */
    'shop_servers', 'shop_users',

    /* other contrib */
    'content', 'views', 'sshkey', 'features', 'adminrole'
  );
}

/**
 * Return a description of the profile for the initial installation screen.
 *
 * @return
 *   An array with keys 'name' and 'description' describing this profile.
 */
function shopmaster_profile_details() {
  return array(
    'name' => 'Hostmaster',
    'description' => 'Select this profile to manage the installation and maintenance of hosted Drupal sites.'
  );
}

function shopmaster_profile_tasks(&$task, $url) {
  // Install dependencies
  install_include(shopmaster_profile_modules());

  // add support for nginx
  if (d()->platform->server->http_service_type === 'nginx') {
    drupal_install_modules(array('hosting_nginx'));
  }

  // Bootstrap and create all the initial nodes
  shopmaster_bootstrap();

  // Finalize and setup themes, menus, optional modules etc
  shopmaster_task_finalize();
}

function shopmaster_bootstrap() {
  /* Default node types and default node */
  $types =  node_types_rebuild();

  variable_set('install_profile', 'shopmaster');
  // Initialize the hosting defines
  hosting_init();

  /* Default client */
  $node = new stdClass();
  $node->uid = 1;
  $node->type = 'client';
  $node->title = drush_get_option('client_name', 'admin');
  $node->status = 1;
  node_save($node);
  variable_set('hosting_default_client', $node->nid);
  variable_set('hosting_admin_client', $node->nid);

  $client_id = $node->nid;

  /* Default server */
  $node = new stdClass();
  $node->uid = 1;
  $node->type = 'server';
  $node->title = php_uname('n');
  $node->status = 1;
  $node->hosting_name = 'server_master';
  $node->services = array();

  /* Make it compatible with more than apache and nginx */
  $master_server = d()->platform->server;
  hosting_services_add($node, 'http', $master_server->http_service_type, array(
   'restart_cmd' => $master_server->http_restart_cmd,
   'port' => 80,
   'available' => 1,
  ));

  /* examine the db server associated with the shopmaster site */
  $db_server = d()->db_server;
  $master_db = parse_url($db_server->master_db);
  /* if it's not the same server as the master server, create a new node
   * for it */
  if ($db_server->remote_host == $master_server->remote_host) {
    $db_node = $node;
  } else {
    $db_node = new stdClass();
    $db_node->uid = 1;
    $db_node->type = 'server';
    $db_node->title = $master_db['host'];
    $db_node->status = 1;
    $db_node->hosting_name = 'server_' . $db_server->remote_host;
    $db_node->services = array();
  }
  hosting_services_add($db_node, 'db', $db_server->db_service_type, array(
    'db_type' => $master_db['scheme'],
    'db_user' => urldecode($master_db['user']),
    'db_passwd' => urldecode($master_db['pass']),
    'port' => 3306,
    'available' => 1,
  ));

  drupal_set_message(st('Creating master server node'));
  node_save($node);
  if ($db_server->remote_host != $master_server->remote_host) {
    drupal_set_message(st('Creating db server node'));
    node_save($db_node);
  }
  variable_set('hosting_default_web_server', $node->nid);
  variable_set('hosting_own_web_server', $node->nid);

  variable_set('hosting_default_db_server', $db_node->nid);
  variable_set('hosting_own_db_server', $db_node->nid);

  $node = new stdClass();
  $node->uid = 1;
  $node->title = 'Drupal';
  $node->type = 'package';
  $node->package_type = 'platform';
  $node->short_name = 'drupal';
  $node->status = 1;
  node_save($node);
  $package_id = $node->nid;

  $node = new stdClass();
  $node->uid = 1;
  $node->type = 'platform';
  $node->title = 'hostmaster';
  $node->publish_path = d()->root;
  $node->web_server = variable_get('hosting_default_web_server', 2);
  $node->status = 1;
  node_save($node);
  $platform_id = $node->nid;
  variable_set('hosting_own_platform', $node->nid);


  $instance = new stdClass();
  $instance->rid = $node->nid;
  $instance->version = VERSION;
  $instance->schema_version = drupal_get_installed_schema_version('system');
  $instance->package_id = $package_id;
  $instance->status = 0;
  hosting_package_instance_save($instance);

  // Create the shopmaster profile node
  $node = new stdClass();
  $node->uid = 1;
  $node->title = 'shopmaster';
  $node->type = 'package';
  $node->package_type = 'profile';
  $node->short_name = 'shopmaster';
  $node->status = 1;
  node_save($node);

  $profile_id = $node->nid;

  // Create the main Aegir site node
  $node = new stdClass();
  $node->uid = 1;
  $node->type = 'site';
  $node->title = d()->uri;
  $node->platform = $platform_id;
  $node->client = $client_id;
  $node->db_server = $db_node->nid;
  $node->profile = $profile_id;
  $node->import = true;
  $node->hosting_name = 'hostmaster';
  $node->status = 1;
  node_save($node);

  variable_set('site_frontpage', 'hosting/servers');
  variable_set('site_name', 'Devudo');
  variable_set('site_slogan', 'Shopmaster');
  variable_set('site_mission', 'Welcome to Devudo ShopMaster.  If you are seeing this, you are a part of our alpha testing team.');
  variable_set('site_footer','&copy; 2013 Devudo Inc, ThinkDrop Consulting LLC');

  // do not allow user registration: the signup form will do that
  variable_set('user_register', 0);

  // This is saved because the config generation script is running via drush, and does not have access to this value
  variable_set('install_url' , $GLOBALS['base_url']);
}

function shopmaster_task_finalize() {
  variable_set('install_profile', 'shopmaster');
  drupal_set_message(st('Configuring menu items'));

  install_include(array('menu'));
  $menu_name = variable_get('menu_primary_links_source', 'primary-links');

  // @TODO - seriously need to simplify this, but in our own code i think, not install profile api
  $items = install_menu_get_items('hosting/servers');
  $item = db_fetch_array(db_query("SELECT * FROM {menu_links} WHERE mlid = %d", $items[0]['mlid']));
  $item['menu_name'] = $menu_name;
  $item['customized'] = 1;
  $item['options'] = unserialize($item['options']);
  install_menu_update_menu_item($item);

  //$items = install_menu_get_items('hosting/sites');
  //$item = db_fetch_array(db_query("SELECT * FROM {menu_links} WHERE mlid = %d", $items[0]['mlid']));
  //$item['menu_name'] = $menu_name;
  //$item['customized'] = 1;
  //$item['options'] = unserialize($item['options']);
  //install_menu_update_menu_item($item);

  //$items = install_menu_get_items('hosting/platforms');
  //$item = db_fetch_array(db_query("SELECT * FROM {menu_links} WHERE mlid = %d", $items[0]['mlid']));
  //$item['menu_name'] = $menu_name;
  //$item['customized'] = 1;
  //$item['options'] = unserialize($item['options']);
  //install_menu_update_menu_item($item);

  menu_rebuild();

  $theme = 'eldir';
  drupal_set_message(st('Configuring Bluemarine theme'));
  install_disable_theme('garland');
  install_default_theme('bluemarine');
  system_theme_data();

  db_query("DELETE FROM {cache}");

  drupal_set_message(st('Configuring default blocks'));
  install_add_block('hosting', 'hosting_queues', $theme, 1, 5, 'right', 1);

  node_access_rebuild();
  features_revert();
  features_revert();
  cache_clear_all();
  cache_clear_all();
}