module Styles = {
  open Css;

  let square = (bgColor, textColor, borderColor) =>
    style([
      display(`flex),
      flexDirection(`column),
      justifyContent(`flexStart),
      alignItems(`center),
      height(`rem(24.)),
      width(`rem(24.)),
      backgroundColor(bgColor),
      selector("h1", [color(textColor), fontFamily(Fonts.ibmplexsans)]),
      borderRadius(`px(6)),
      border(`px(2), `solid, borderColor),
      boxShadow(
        Shadow.box(
          ~x=`zero,
          ~y=`px(10),
          ~blur=`px(30),
          `rgba((61, 88, 120, 0.25)),
        ),
      ),
    ]);

  let blink = keyframes([(0, []), (100, [opacity(0.)])]);

  let blinkingSquare = (bgColor, textColor, borderColor) =>
    merge([
      square(bgColor, textColor, borderColor),
      style([animation(blink, ~duration=1000, ~iterationCount=`infinite)]),
    ]);

  let blockText = (textColor, textSize, top) =>
    style([
      marginTop(top),
      height(`rem(20.)),
      width(`rem(20.)),
      overflowWrap(`breakWord),
      fontFamily(Fonts.ocrastud),
      fontSize(textSize),
      color(textColor),
    ]);

  let heading = style([fontFamily("Aktiv Grotesk Bold")]);
};

[@react.component]
let make =
    (
      ~bgColor,
      ~textColor,
      ~borderColor,
      ~heading="",
      ~text={
              React.string("");
            },
      ~active=false,
      ~textSize=`rem(1.56),
      ~marginTop=`zero,
    ) =>
  <div
    className={
      active
        ? Styles.square(
            Colors.thirdBgActive,
            Colors.offWhite,
            Colors.thirdBgActive,
          )
        : Styles.square(bgColor, textColor, borderColor)
    }>
    <h1 className=Styles.heading> {React.string(heading)} </h1>
    <div
      className={
        active
          ? Styles.blockText(Colors.offWhite, textSize, marginTop)
          : Styles.blockText(textColor, textSize, marginTop)
      }>
      text
    </div>
  </div>;