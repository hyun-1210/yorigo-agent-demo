function main() {
  var cartAddUsers = Events({
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  })
    .filter(function(e) {
      return e.name === "recipe_cart_add_footer_clicked" ||
             e.name === "recipe_ingredient_add_clicked";
    })
    .groupByUser(mixpanel.reducer.count());

  var purchaseUsers = Events({
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  })
    .filter(function(e) {
      return e.name === "cart_purchase_completed" ||
             e.name === "ingredient_purchased";
    })
    .groupByUser(mixpanel.reducer.count());

  var affiliateUsers = Events({
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  })
    .filter(function(e) {
      return e.name === "affiliate_link_clicked";
    })
    .groupByUser(mixpanel.reducer.count());

  var checkedUsers = Events({
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  })
    .filter(function(e) {
      return e.name === "ingredient_purchase_checked" &&
             e.properties.checked === 1;
    })
    .groupByUser(mixpanel.reducer.count());

  function keys(set) {
    var out = {};
    for (var i = 0; i < set.length; i++) {
      out[set[i].key] = true;
    }
    return out;
  }

  var cartKeys = keys(cartAddUsers);
  var purchaseKeys = keys(purchaseUsers);
  var affiliateKeys = keys(affiliateUsers);
  var checkedKeys = keys(checkedUsers);

  var cartCount = cartAddUsers.length;
  var purchaseCount = purchaseUsers.length;
  var affiliateCount = affiliateUsers.length;
  var checkedCount = checkedUsers.length;

  var cartToPurchase = 0;
  var cartToAffiliate = 0;
  var checkedToPurchase = 0;
  var checkedToAffiliate = 0;

  for (var id in cartKeys) {
    if (purchaseKeys[id]) cartToPurchase++;
    if (affiliateKeys[id]) cartToAffiliate++;
  }
  for (var id2 in checkedKeys) {
    if (purchaseKeys[id2]) checkedToPurchase++;
    if (affiliateKeys[id2]) checkedToAffiliate++;
  }

  return {
    cart_add_unique_users: cartCount,
    ingredient_checked_unique_users: checkedCount,
    purchase_completed_unique_users: purchaseCount,
    affiliate_click_unique_users: affiliateCount,
    cart_add_to_purchase_users: cartToPurchase,
    cart_add_to_affiliate_users: cartToAffiliate,
    ingredient_checked_to_purchase_users: checkedToPurchase,
    ingredient_checked_to_affiliate_users: checkedToAffiliate
  };
}
